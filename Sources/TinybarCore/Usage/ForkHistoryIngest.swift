import Foundation

/// Counts the Grok CLI's and Antigravity's history into the same daily rows as Claude Code's and
/// Codex's logs (ADR 0017). Kept apart from `UsageStore.swift` so the daily rebase onto upstream
/// stays clean; `ingestAll` and `daily` each call in once.
extension UsageStore {
    /// `fork_cursor`: each read file's stamp, and for Grok's JSONL how far it was read.
    /// `fork_record`: what was counted for each response, so a later, fuller read of the same one
    /// adds only the difference. `fork_key`: every id a response is known by.
    static let forkHistorySchema = """
    CREATE TABLE IF NOT EXISTS fork_cursor (path TEXT PRIMARY KEY, stamp TEXT NOT NULL, offset INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS fork_record (
        id INTEGER PRIMARY KEY,
        day TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        project TEXT NOT NULL,
        input INTEGER NOT NULL,
        output INTEGER NOT NULL,
        cache_write INTEGER NOT NULL,
        cache_read INTEGER NOT NULL,
        cost_micros INTEGER
    );
    CREATE INDEX IF NOT EXISTS fork_record_day ON fork_record (day);
    CREATE TABLE IF NOT EXISTS fork_key (key TEXT PRIMARY KEY, record INTEGER NOT NULL) WITHOUT ROWID;
    """

    /// Reads what changed since the last call. A file that can't be read is left for the next one
    /// and doesn't stop the others. Returns the responses added.
    @discardableResult
    func ingestForkHistory(
        grokRoot: URL = GrokHistory.sessionsRoot(),
        antigravityRoots: [URL] = AntigravityHistory.conversationRoots()) throws -> Int
    {
        try db.exec(Self.forkHistorySchema)
        var added = 0
        var grokFiles: [(String, FileStamp)] = []
        try Self.walkJSONL(grokRoot.path) { path, stamp in
            if path.hasSuffix("/" + GrokHistory.fileName) { grokFiles.append((path, stamp)) }
        }
        for (path, stamp) in grokFiles {
            let known = try forkCursor(path)
            let key = Self.stampKey(stamp, nil)
            guard known?.stamp != key else { continue }
            // A file that shrank or was replaced is read again from the start; responses count once anyway.
            let from = known.map { $0.stamp.hasPrefix("\(stamp.inode):") && $0.offset <= stamp.size ? $0.offset : 0 } ?? 0
            var records: [HistoryRecord] = []
            let cwd = GrokHistory.cwd(ofFile: path, root: grokRoot.path)
            guard let end = try? JSONLReader.forEachLine(url: URL(fileURLWithPath: path), from: from, { line in
                guard Self.contains(line, "turn_completed") else { return }
                records += GrokHistory.records(line: Data(line), cwd: cwd)
            }) else { continue }
            try db.transaction {
                added += try count(records, provider: .grok)
                try saveForkCursor(path, stamp: key, offset: end)
            }
        }
        for path in AntigravityHistory.databases(in: antigravityRoots) {
            guard let stamp = Self.stamp(path) else { continue }
            let key = Self.stampKey(stamp, Self.stamp(path + "-wal"))
            guard try forkCursor(path)?.stamp != key, let records = AntigravityHistory.read(database: path) else { continue }
            try db.transaction {
                added += try count(records, provider: .gemini)
                try saveForkCursor(path, stamp: key, offset: 0)
            }
        }
        return added
    }

    /// Adds each record, or what it holds beyond the copy already counted. Returns the new ones.
    private func count(_ records: [HistoryRecord], provider: ProviderID) throws -> Int {
        var added = 0
        for record in records {
            let quoted = record.keys.map { _ in "?" }.joined(separator: ", ")
            let existing = try db.run("SELECT record FROM fork_key WHERE key IN (\(quoted)) LIMIT 1", record.keys.map { .text($0) }).first?.first?.int
            let costMicros = record.cost.map { Int64(($0 * 1_000_000).rounded()) }
            if let id = existing, let row = try db.run(
                "SELECT day, model, project, input, output, cache_write, cache_read, cost_micros FROM fork_record WHERE id = ?", [.int(id)]).first
            {
                let had = TokenCounts(input: row[3].int, output: row[4].int, cacheWrite: row[5].int, cacheRead: row[6].int)
                let now = TokenCounts(
                    input: max(had.input, record.tokens.input), output: max(had.output, record.tokens.output),
                    cacheWrite: max(had.cacheWrite, record.tokens.cacheWrite), cacheRead: max(had.cacheRead, record.tokens.cacheRead))
                let cost: Int64? = switch (row[7], costMicros) {
                case let (.int(old), new?): max(old, new)
                case (.int(let old), nil): old
                default: costMicros
                }
                if now != had || cost != row[7].optionalInt {
                    try addTokens(day: row[0].text ?? "", provider: provider, model: row[1].text ?? "", project: row[2].text ?? "",
                                  machine: RemoteHosts.thisMac, { var d = now; d += -had; return d }())
                    try db.run("""
                    UPDATE fork_record SET input = ?, output = ?, cache_write = ?, cache_read = ?, cost_micros = ? WHERE id = ?
                    """, [.int(now.input), .int(now.output), .int(now.cacheWrite), .int(now.cacheRead), cost.map { .int($0) } ?? .null, .int(id)])
                }
                for key in record.keys { try db.run("INSERT OR IGNORE INTO fork_key (key, record) VALUES (?, ?)", [.text(key), .int(id)]) }
                continue
            }
            let day = DayKey.string(for: record.timestamp)
            let model = ModelName.normalize(record.model)
            let project = projects.project(for: record.cwd)
            try db.run("""
            INSERT INTO fork_record (day, provider, model, project, input, output, cache_write, cache_read, cost_micros)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(day), .text(provider.rawValue), .text(model), .text(project), .int(record.tokens.input), .int(record.tokens.output),
                  .int(record.tokens.cacheWrite), .int(record.tokens.cacheRead), costMicros.map { .int($0) } ?? .null])
            guard let id = try db.run("SELECT last_insert_rowid()").first?.first?.int else { continue }
            for key in record.keys { try db.run("INSERT OR IGNORE INTO fork_key (key, record) VALUES (?, ?)", [.text(key), .int(id)]) }
            try addTokens(day: day, provider: provider, model: model, project: project, machine: RemoteHosts.thisMac, record.tokens)
            added += 1
        }
        return added
    }

    /// What each day's rows cost as their CLI priced them, for those it priced (Grok).
    func withReportedCosts(_ rows: [DailyUsage], since: String) throws -> [DailyUsage] {
        try db.exec(Self.forkHistorySchema)
        var costs: [String: Double] = [:]
        for r in try db.run("""
        SELECT day, provider, model, project, sum(cost_micros) FROM fork_record
        WHERE day >= ? AND cost_micros IS NOT NULL GROUP BY day, provider, model, project
        """, [.text(since)]) {
            costs[[r[0].text, r[1].text, r[2].text, r[3].text].map { $0 ?? "" }.joined(separator: "\u{1F}")] = Double(r[4].int) / 1_000_000
        }
        guard !costs.isEmpty else { return rows }
        return rows.map { row in
            guard row.machine == RemoteHosts.thisMac else { return row }
            var row = row
            row.reportedCost = costs[[row.day, row.provider.rawValue, row.model, row.project].joined(separator: "\u{1F}")]
            return row
        }
    }

    private func forkCursor(_ path: String) throws -> (stamp: String, offset: Int64)? {
        try db.run("SELECT stamp, offset FROM fork_cursor WHERE path = ?", [.text(path)]).first.map { ($0[0].text ?? "", $0[1].int) }
    }

    private func saveForkCursor(_ path: String, stamp: String, offset: Int64) throws {
        try db.run("INSERT OR REPLACE INTO fork_cursor (path, stamp, offset) VALUES (?, ?, ?)", [.text(path), .text(stamp), .int(offset)])
    }

    /// A database's WAL holds its newest rows, so it is part of the database's stamp.
    private static func stampKey(_ file: FileStamp, _ wal: FileStamp?) -> String {
        "\(file.inode):\(file.size):\(file.mtime)" + (wal.map { "/\($0.size):\($0.mtime)" } ?? "")
    }

    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: String) -> Bool {
        needle.utf8CString.withUnsafeBufferPointer { n in
            memmem(line.baseAddress, line.count, n.baseAddress, n.count - 1) != nil
        }
    }
}

extension SQLiteDB.Value {
    var optionalInt: Int64? {
        if case let .int(v) = self { return v }
        return nil
    }
}

/// `tinybar-cli history`: what the readers find, without a store.
public enum HistoryReaders {
    public static func summaries() -> [(String, [String])] {
        func lines(_ records: [HistoryRecord]) -> [String] {
            var byModel: [String: (count: Int, tokens: TokenCounts, cost: Double?)] = [:]
            var seen = Set<String>()
            for r in records where r.keys.allSatisfy({ !seen.contains($0) }) {
                r.keys.forEach { seen.insert($0) }
                var entry = byModel[r.model] ?? (0, TokenCounts(), nil)
                entry.count += 1
                entry.tokens += r.tokens
                if let c = r.cost { entry.cost = (entry.cost ?? 0) + c }
                byModel[r.model] = entry
            }
            return byModel.sorted { $0.value.tokens.total > $1.value.tokens.total }.map { model, e in
                "\(model): \(e.count) responses, \(e.tokens.total) tokens (in \(e.tokens.input), out \(e.tokens.output), cache r/w \(e.tokens.cacheRead)/\(e.tokens.cacheWrite))"
                    + (e.cost.map { String(format: ", $%.2f", $0) } ?? "")
            }
        }
        let root = GrokHistory.sessionsRoot()
        var grok: [HistoryRecord] = []
        try? UsageStore.walkJSONL(root.path) { path, _ in
            guard path.hasSuffix("/" + GrokHistory.fileName) else { return }
            let cwd = GrokHistory.cwd(ofFile: path, root: root.path)
            _ = try? JSONLReader.forEachLine(url: URL(fileURLWithPath: path), from: 0) { grok += GrokHistory.records(line: Data($0), cwd: cwd) }
        }
        let roots = AntigravityHistory.conversationRoots()
        let databases = AntigravityHistory.databases(in: roots)
        var antigravity: [HistoryRecord] = []
        var unreadable: [String] = []
        for path in databases {
            if let r = AntigravityHistory.read(database: path) { antigravity += r } else { unreadable.append(path) }
        }
        return [
            ("Grok (\(root.path))", lines(grok)),
            ("Antigravity (\(databases.count) databases in \(roots.map(\.path).joined(separator: ", ")))",
             lines(antigravity) + unreadable.map { "unreadable: \($0)" }),
        ]
    }
}
