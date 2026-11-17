import Foundation

extension UsageStore {
    /// Before schema 10, usage read from `RemoteHosts` was filed as this Mac's. Reads those logs
    /// again, up to what had been counted then, and moves their usage to their machine: a Claude
    /// message's exact count while its id is kept, otherwise what the log holds, never more than
    /// this Mac has under the same day, model and project. Runs once, in the history import's
    /// child process.
    public func assignMachines(progress: (@Sendable (IngestProgress) -> Void)? = nil) throws {
        guard try !hasAssignedMachines() else { return }
        let limits = try db.run("""
        SELECT substr(key, length('machines_limit:') + 1), CAST(value AS INTEGER) FROM meta WHERE key GLOB 'machines_limit:*'
        """).compactMap { r -> (path: String, limit: Int64)? in r[0].text.map { ($0, r[1].int) } }
        let hosts = Set(limits.map { RemoteLogs.machine(of: $0.path) })
        for host in hosts.sorted() where !RemoteLogs.isReachable(host) {
            throw ProviderError.unexpected("Couldn't reach \(host) to read its logs")
        }

        struct Key: Hashable {
            var day, model, project, machine: String
            var provider: ProviderID
            var band: Int64?
        }
        var claude: [String: (message: ClaudeMessage, machine: String)] = [:]
        var codex: [Key: TokenCounts] = [:]
        for (index, (path, limit)) in limits.enumerated() {
            let machine = RemoteLogs.machine(of: path)
            // A log gone since then can't be told apart from this Mac's any more.
            if try db.run("SELECT provider FROM file_cursor WHERE path = ?", [.text(path)]).first?.first?.text == LogSource.codex.rawValue {
                var parser = CodexLogParser()
                _ = try? JSONLReader.forEachLine(url: URL(fileURLWithPath: path), from: 0, until: limit) { line in
                    guard let record = parser.consume(line: line) else { return }
                    var key = Key(day: DayKey.string(for: record.timestamp), model: ModelName.normalize(record.model),
                                  project: projects.project(for: record.cwd), machine: machine, provider: .codex)
                    codex[key, default: TokenCounts()] += record.tokens
                    if let band = ContextBand.of(record.tokens) {
                        key.band = band
                        codex[key, default: TokenCounts()] += record.tokens
                    }
                }
            } else {
                var session = ClaudeLogParser.Session(subagentFile: path.contains("/subagents/"))
                _ = try? JSONLReader.forEachLine(url: URL(fileURLWithPath: path), from: 0, until: limit) { line in
                    for case let .message(m) in session.consume(line: line) {
                        if claude[m.entry.messageID] != nil {
                            claude[m.entry.messageID]!.message.merge(m)
                        } else {
                            claude[m.entry.messageID] = (ClaudeMessage(m), machine)
                        }
                    }
                }
            }
            if index % 50 == 49 { progress?(IngestProgress(filesDone: index + 1, filesTotal: limits.count)) }
        }

        try db.transaction {
            for (id, found) in claude {
                if let r = try db.run("""
                    SELECT day, provider, model, project, input, output, cache_write, cache_read FROM claude_message
                    WHERE id = ? AND machine = ?
                    """, [.text(id), .text(RemoteHosts.thisMac)]).first
                {
                    guard let provider = r[1].text.flatMap(ProviderID.init(rawValue:)) else { continue }
                    let t = TokenCounts(input: r[4].int, output: r[5].int, cacheWrite: r[6].int, cacheRead: r[7].int)
                    let key = Key(day: r[0].text ?? "", model: r[2].text ?? "", project: r[3].text ?? "", machine: found.machine, provider: provider)
                    try move(t, key)
                    if let band = ContextBand.of(t) { try move(t, Key(day: key.day, model: key.model, project: key.project, machine: key.machine, provider: provider, band: band)) }
                    try db.run("UPDATE claude_message SET machine = ? WHERE id = ?", [.text(found.machine), .text(id)])
                } else if try db.run("SELECT 1 FROM claude_message WHERE id = ?", [.text(id)]).isEmpty {
                    let record = found.message.record
                    let model = ModelName.normalize(record.model)
                    var key = Key(day: DayKey.string(for: record.timestamp), model: model, project: projects.project(for: record.cwd),
                                  machine: found.machine, provider: ClaudeLogParser.provider(forModel: model))
                    try move(record.tokens, key)
                    if let band = ContextBand.of(record.tokens) {
                        key.band = band
                        try move(record.tokens, key)
                    }
                }
            }
            for (key, t) in codex { try move(t, key) }
            try db.exec("""
            INSERT OR REPLACE INTO meta (key, value) VALUES ('machines', 'done');
            DELETE FROM meta WHERE key GLOB 'machines_limit:*';
            DELETE FROM daily_usage WHERE input = 0 AND output = 0 AND cache_write = 0 AND cache_read = 0;
            DELETE FROM daily_long_context WHERE input = 0 AND output = 0 AND cache_write = 0 AND cache_read = 0;
            """)
        }

        /// Moves up to `t` from this Mac's row to the machine's.
        func move(_ t: TokenCounts, _ key: Key) throws {
            let table = key.band == nil ? "daily_usage" : "daily_long_context"
            var params: [SQLiteDB.Value] = [.text(key.day), .text(key.provider.rawValue), .text(key.model), .text(key.project), .text(RemoteHosts.thisMac)]
            if let band = key.band { params.append(.int(band)) }
            guard let row = try db.run("""
                SELECT input, output, cache_write, cache_read FROM \(table)
                WHERE day = ? AND provider = ? AND model = ? AND project = ? AND machine = ?\(key.band == nil ? "" : " AND band = ?")
                """, params).first
            else { return }
            let have = [row[0].int, row[1].int, row[2].int, row[3].int]
            let want = [t.input, t.output, t.cacheWrite, t.cacheRead]
            let m = zip(want, have).map { min(max($0, 0), max($1, 0)) }
            let moved = TokenCounts(input: m[0], output: m[1], cacheWrite: m[2], cacheRead: m[3])
            guard !moved.isZero else { return }
            if let band = key.band {
                try addLong(day: key.day, provider: key.provider, model: key.model, project: key.project, machine: RemoteHosts.thisMac, band: band, -moved)
                try addLong(day: key.day, provider: key.provider, model: key.model, project: key.project, machine: key.machine, band: band, moved)
            } else {
                try addDaily(day: key.day, provider: key.provider, model: key.model, project: key.project, machine: RemoteHosts.thisMac, -moved)
                try addDaily(day: key.day, provider: key.provider, model: key.model, project: key.project, machine: key.machine, moved)
            }
        }
    }

    public func hasAssignedMachines() throws -> Bool {
        try db.run("SELECT value FROM meta WHERE key = 'machines'").first?.first?.text == "done"
    }
}
