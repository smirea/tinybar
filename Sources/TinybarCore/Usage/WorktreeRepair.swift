import Foundation

extension UsageStore {
    /// Before `AgentWorktree`, usage in a deleted agent worktree was filed under the folder's own
    /// name: an id, or a subfolder such as `app-ios` that several repos have. This reads the folders
    /// each day's usage of each model came from out of the logs, and moves it from such a name to the
    /// repo when the name meant only that repo for that day and model. Claude messages still kept for
    /// de-duplication move one by one whatever the name meant. Usage whose logs are gone stays where it
    /// is. Runs once, in the history import's child process.
    public func repairWorktreeProjects(progress: (@Sendable (IngestProgress) -> Void)? = nil) throws {
        try repairWorktreeProjects(
            roots: LogSource.allCases.flatMap { source in source.roots.map { ($0, source) } },
            hosts: RemoteHosts.all, progress: progress)
    }

    func repairWorktreeProjects(roots: [(URL, LogSource)], hosts: [String], progress: (@Sendable (IngestProgress) -> Void)? = nil) throws {
        guard try !hasRepairedWorktreeProjects() else { return }
        // A host that doesn't answer would leave its usage behind for good.
        for host in hosts where !RemoteLogs.isReachable(host) {
            throw ProviderError.unexpected("Couldn't reach \(host) to read its logs")
        }
        var files: [(path: String, source: LogSource)] = []
        for (root, source) in roots {
            try Self.walkJSONL(root.path) { path, _ in files.append((path, source)) }
        }

        struct Slot: Hashable { var day, model, name: String }
        var repos: [Slot: Set<String>] = [:]
        var legacy: [String: String?] = [:]
        var messages: [String: (name: String, repo: String)] = [:]
        let cwdKey = Array(#""cwd":""#.utf8)
        let usageKey = Array(#""token_count""#.utf8)
        // Codex tool calls carry their own `cwd`; only these lines say where the turn runs.
        let turnKeys = [#""type":"turn_context""#, #""type":"session_meta""#].map { Array($0.utf8) }
        for (index, (path, source)) in files.enumerated() {
            // Codex names the folder and model once per turn, and a turn's usage can fall on the next day.
            var turn: (name: String?, repo: String, model: String?)?
            // A log deleted since it was listed has nothing left to say.
            _ = try? JSONLReader.forEachLine(url: URL(fileURLWithPath: path), from: 0) { line in
                func has(_ key: [UInt8]) -> Bool { memmem(line.baseAddress, line.count, key, key.count) != nil }
                let hasCwd = has(cwdKey) && (source == .claude || turnKeys.contains(where: has))
                guard hasCwd || turn?.name != nil && has(usageKey) else { return }
                let data = Data(line)
                if hasCwd, let cwd = CodexLogParser.stringField("cwd", in: data) {
                    let name: String?
                    if let known = legacy[cwd] {
                        name = known
                    } else {
                        name = projects.legacyName(for: cwd)
                        legacy[cwd] = name
                    }
                    turn = (name, projects.project(for: cwd), CodexLogParser.stringField("model", in: data).map(ModelName.normalize) ?? turn?.model)
                }
                // Lines without a model (prompts, session headers) carry no usage.
                guard let turn, let name = turn.name, let model = turn.model,
                      let at = CodexLogParser.stringField("timestamp", in: data).flatMap(parseISODate) else { return }
                repos[Slot(day: DayKey.string(for: at), model: model, name: name), default: []].insert(turn.repo)
                if source == .claude, let entry = ClaudeLogParser.parse(line: line) {
                    messages[entry.messageID] = (name, turn.repo)
                }
            }
            if index % 200 == 199 { progress?(IngestProgress(filesDone: index + 1, filesTotal: files.count)) }
        }

        try db.transaction {
            for (slot, targets) in repos where targets.count == 1 {
                let repo = targets.first!
                guard repo != slot.name else { continue }
                try moveProject(day: slot.day, model: slot.model, from: slot.name, to: repo)
            }
            for (id, move) in messages where move.repo != move.name {
                try moveClaudeMessage(id: id, from: move.name, to: move.repo)
            }
            let empty = "project NOT LIKE '/%' AND input = 0 AND output = 0 AND cache_write = 0 AND cache_read = 0"
            try db.run("DELETE FROM daily_usage WHERE \(empty)")
            try db.run("DELETE FROM daily_long_context WHERE \(empty)")
            try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('worktree_projects', 'done')")
        }
    }

    public func hasRepairedWorktreeProjects() throws -> Bool {
        try db.run("SELECT value FROM meta WHERE key = 'worktree_projects'").first?.first?.text == "done"
    }

    private func moveClaudeMessage(id: String, from old: String, to new: String) throws {
        guard let r = try db.run(
            "SELECT day, provider, model, input, output, cache_write, cache_read, machine FROM claude_message WHERE id = ? AND project = ?",
            [.text(id), .text(old)]).first,
            let day = r[0].text, let provider = r[1].text.flatMap(ProviderID.init(rawValue:)), let model = r[2].text, let machine = r[7].text
        else { return }
        let t = TokenCounts(input: r[3].int, output: r[4].int, cacheWrite: r[5].int, cacheRead: r[6].int)
        try addDaily(day: day, provider: provider, model: model, project: old, machine: machine, -t)
        try addDaily(day: day, provider: provider, model: model, project: new, machine: machine, t)
        if let band = ContextBand.of(t) {
            try addLong(day: day, provider: provider, model: model, project: old, machine: machine, band: band, -t)
            try addLong(day: day, provider: provider, model: model, project: new, machine: machine, band: band, t)
        }
        try db.run("UPDATE claude_message SET project = ? WHERE id = ?", [.text(new), .text(id)])
    }

    private func moveProject(day: String, model: String, from old: String, to new: String) throws {
        let tokens = "input = input + excluded.input, output = output + excluded.output, cache_write = cache_write + excluded.cache_write, cache_read = cache_read + excluded.cache_read"
        let params: [SQLiteDB.Value] = [.text(new), .text(day), .text(model), .text(old)]
        let filter = "WHERE day = ? AND model = ? AND project = ?"
        try db.run("""
        INSERT INTO daily_usage (day, provider, model, project, machine, input, output, cache_write, cache_read)
        SELECT day, provider, model, ?, machine, input, output, cache_write, cache_read FROM daily_usage \(filter)
        ON CONFLICT(day, provider, model, project, machine) DO UPDATE SET \(tokens)
        """, params)
        try db.run("""
        INSERT INTO daily_long_context (day, provider, model, project, machine, band, input, output, cache_write, cache_read)
        SELECT day, provider, model, ?, machine, band, input, output, cache_write, cache_read FROM daily_long_context \(filter)
        ON CONFLICT(day, provider, model, project, machine, band) DO UPDATE SET \(tokens)
        """, params)
        try db.run("DELETE FROM daily_usage \(filter)", Array(params.dropFirst()))
        try db.run("DELETE FROM daily_long_context \(filter)", Array(params.dropFirst()))
        // Later copies of these messages correct the totals under the project they now count in.
        try db.run("UPDATE claude_message SET project = ? \(filter)", params)
    }
}
