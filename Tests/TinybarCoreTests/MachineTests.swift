import Foundation
@testable import TinybarCore
import Testing

/// A store as 0.15 left it: no machine anywhere.
private func nineStore(remoteCursor: Bool) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    _ = try UsageStore(path: url)
    let db = try SQLiteDB(path: url.path)
    try db.exec("""
    DROP TABLE daily_usage; DROP TABLE daily_long_context; DROP TABLE claude_message;
    CREATE TABLE daily_usage (day TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, project TEXT NOT NULL,
        input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
        cache_read INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (day, provider, model, project)) WITHOUT ROWID;
    CREATE TABLE daily_long_context (day TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, project TEXT NOT NULL,
        band INTEGER NOT NULL, input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
        cache_write INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (day, provider, model, project, band)) WITHOUT ROWID;
    CREATE TABLE claude_message (id TEXT PRIMARY KEY, day TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
        project TEXT NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL, cache_write INTEGER NOT NULL,
        cache_read INTEGER NOT NULL, stats TEXT) WITHOUT ROWID;
    INSERT INTO daily_usage VALUES ('2026-11-16', 'claude', 'm', '/repo', 1, 2, 3, 4);
    INSERT INTO daily_long_context VALUES ('2026-11-16', 'claude', 'm', '/repo', 200000, 1, 0, 0, 0);
    INSERT INTO claude_message VALUES ('a', '2026-11-16', 'claude', 'm', '/repo', 1, 2, 3, 4, NULL);
    DELETE FROM meta WHERE key GLOB 'machines*';
    PRAGMA user_version = 9;
    """)
    if remoteCursor {
        try db.run("INSERT INTO file_cursor VALUES ('/@mini/.claude/projects/p/s.jsonl', 'claude', 1, 10, 0, 10, NULL)")
    }
    return url
}

@Test func upgradeKeepsUsageAsThisMacsUntilRemoteLogsAreReadAgain() async throws {
    let url = try nineStore(remoteCursor: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try UsageStore(path: url)
    let rows = try await store.daily(since: "2026-01-01")
    #expect(rows.map(\.machine) == [RemoteHosts.thisMac])
    #expect(rows.first?.tokens.total == 10)
    #expect(rows.first?.long[200_000]?.input == 1)
    #expect(try await !store.hasAssignedMachines())
    let db = try SQLiteDB(path: url.path)
    #expect(try db.run("SELECT value FROM meta WHERE key = 'machines_limit:/@mini/.claude/projects/p/s.jsonl'").first?.first?.text == "10")
    #expect(try db.run("SELECT machine FROM claude_message").first?.first?.text == "")
}

@Test func upgradeWithoutRemoteLogsHasNothingToAssign() async throws {
    let url = try nineStore(remoteCursor: false)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try await UsageStore(path: url).hasAssignedMachines())
}

@Test func newStoreHasNothingToAssign() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try await UsageStore(path: url).hasAssignedMachines())
}

@Test func remoteLogsBelongToTheirHost() {
    #expect(RemoteLogs.machine(of: "/@mini/.codex/sessions/r.jsonl") == "mini")
    #expect(RemoteLogs.machine(of: "/Users/me/.codex/sessions/r.jsonl") == RemoteHosts.thisMac)
}

@Test func summarySplitsUsageByMachineAndProvider() {
    let now = Date()
    let today = DayKey.string(for: now)
    let rows = [
        DailyUsage(day: today, provider: .claude, model: "m", project: "/a", machine: RemoteHosts.thisMac, tokens: TokenCounts(input: 10)),
        DailyUsage(day: today, provider: .claude, model: "m", project: "/a", machine: "mini", tokens: TokenCounts(input: 30)),
        DailyUsage(day: today, provider: .codex, model: "g", project: "/a", machine: "mini", tokens: TokenCounts(input: 5)),
    ]
    let summary = UsageSummary.build(rows: rows, range: .today, prices: PriceTable(prices: [:], fetchedAt: nil), now: now)
    #expect(summary.machines.map(\.name) == ["mini", "This Mac"])
    #expect(summary.machines.first?.byProvider == [.claude: 30, .codex: 5])
    #expect(summary.projects.map(\.tokens) == [45])
}

@Test func frozenOffsetFollowsARolloutCodexMoves() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sessions = dir.appendingPathComponent("sessions"), archive = dir.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("rollout-a.jsonl")
    try #"{"timestamp":"2026-09-25T10:00:00Z","type":"turn_context","payload":{"model":"g"}}"#.appending("\n")
        .write(to: file, atomically: true, encoding: .utf8)
    let url = dir.appendingPathComponent("db.sqlite")
    let store = try UsageStore(path: url)
    try await store.ingestCodex(roots: [sessions])
    let db = try SQLiteDB(path: url.path)
    try db.run("INSERT INTO meta (key, value) VALUES (?, '5')", [.text("machines_limit:" + file.path)])
    let moved = archive.appendingPathComponent(file.lastPathComponent)
    try FileManager.default.moveItem(at: file, to: moved)
    try await store.ingestCodex(roots: [archive])
    #expect(try db.run("SELECT value FROM meta WHERE key = ?", [.text("machines_limit:" + moved.path)]).first?.first?.text == "5")
}
