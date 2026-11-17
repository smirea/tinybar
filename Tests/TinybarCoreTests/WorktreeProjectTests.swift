import Foundation
@testable import TinybarCore
import Testing

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func deletedAgentWorktreesResolveToTheirRepo() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let resolver = ProjectResolver()
    let t3 = home.path + "/.t3/worktrees/shop/t3-4d558998-acfce8ebd1d91371"
    #expect(resolver.project(for: t3) == "shop")
    #expect(resolver.project(for: t3 + "/apps/ios") == "shop")
    #expect(resolver.project(for: home.path + "/.codex/worktrees/a1b2/shop/src") == "shop")
    #expect(resolver.project(for: home.path + "/.t3/scratch/2026-11-13-a-question-8fae4292") == ProjectResolver.noProject)
    #expect(resolver.legacyName(for: t3 + "/apps/ios") == "ios")
    #expect(resolver.legacyName(for: home.path) == nil)
}

@Test func liveAgentWorktreeResolvesToMainRepo() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let repo = home.appendingPathComponent("code/shop")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees/w1"), withIntermediateDirectories: true)
    let wt = home.appendingPathComponent(".t3/worktrees/shop/w1")
    try FileManager.default.createDirectory(at: wt.appendingPathComponent("app"), withIntermediateDirectories: true)
    try "gitdir: \(repo.path)/.git/worktrees/w1\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    #expect(ProjectResolver().project(for: wt.appendingPathComponent("app").path) == repo.path)
}

private func claudeLine(_ id: String, at: String, cwd: String, output: Int) -> String {
    #"{"cwd":"\#(cwd)","type":"assistant","timestamp":"\#(at)","message":{"id":"\#(id)","model":"claude-test","usage":{"input_tokens":0,"output_tokens":\#(output)}}}"# + "\n"
}

@Test func repairMovesUsageFiledUnderDeletedWorktreeFolders() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let claude = dir.appendingPathComponent("claude")
    let codex = dir.appendingPathComponent("codex")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let worktrees = dir.path + "/.t3/worktrees"
    // Two repos' `app` folders on the same day and model, and a worktree folder named by its id.
    try (claudeLine("a", at: "2026-09-25T12:00:00Z", cwd: "\(worktrees)/shop/w1/app", output: 100)
        + claudeLine("c", at: "2026-09-20T12:00:00Z", cwd: "\(worktrees)/shop/w3", output: 1000))
        .write(to: claude.appendingPathComponent("1.jsonl"), atomically: true, encoding: .utf8)
    try claudeLine("b", at: "2026-09-25T12:00:00Z", cwd: "\(worktrees)/blog/w2/app", output: 10)
        .write(to: claude.appendingPathComponent("2.jsonl"), atomically: true, encoding: .utf8)
    // A Codex turn whose usage lands two days after the turn named its folder.
    try [
        #"{"timestamp":"2026-09-10T12:00:00Z","type":"session_meta","payload":{"id":"s","timestamp":"2026-09-10T12:00:00Z","cwd":"\#(worktrees)/blog/w4"}}"#,
        #"{"timestamp":"2026-09-10T12:00:01Z","type":"turn_context","payload":{"cwd":"\#(worktrees)/blog/w4","model":"gpt-test"}}"#,
        #"{"timestamp":"2026-09-10T12:00:02Z","type":"response_item","payload":{"type":"function_call","arguments":{"cwd":"/"}}}"#,
        #"{"timestamp":"2026-09-12T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"output_tokens":0},"total_token_usage":{"input_tokens":7,"output_tokens":0}}}}"#,
    ].joined(separator: "\n").appending("\n").write(to: codex.appendingPathComponent("r.jsonl"), atomically: true, encoding: .utf8)

    let url = dir.appendingPathComponent("db.sqlite")
    let store = try UsageStore(path: url)
    try await store.ingestClaude(roots: [claude])
    try await store.ingestCodex(roots: [codex])
    // File it all as earlier versions did.
    let db = try SQLiteDB(path: url.path)
    try db.exec("""
    UPDATE daily_usage SET project = 'w3' WHERE project = 'shop' AND output = 1000;
    UPDATE claude_message SET project = 'w3' WHERE id = 'c';
    UPDATE daily_usage SET project = 'w4' WHERE provider = 'codex';
    DELETE FROM daily_usage WHERE output = 10;
    UPDATE daily_usage SET project = 'app', output = 110 WHERE output = 100;
    UPDATE claude_message SET project = 'app' WHERE id IN ('a', 'b');
    """)

    try await store.repairWorktreeProjects(roots: [(claude, .claude), (codex, .codex)], hosts: [])
    func totals() async throws -> [String: Int64] {
        Dictionary(try await store.daily(since: "2026-01-01").map { ("\($0.day) \($0.project)", $0.tokens.total) }, uniquingKeysWith: +)
    }
    let day = { (at: String) in DayKey.string(for: parseISODate(at)!) }
    #expect(try await totals() == [
        "\(day("2026-09-25T12:00:00Z")) shop": 100,
        "\(day("2026-09-25T12:00:00Z")) blog": 10,
        "\(day("2026-09-20T12:00:00Z")) shop": 1000,
        "\(day("2026-09-12T12:00:00Z")) blog": 7,
    ])
    #expect(try await store.hasRepairedWorktreeProjects())
}

@Test func repairLeavesAmbiguousUsageWithoutKeptMessages() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let worktrees = dir.path + "/.t3/worktrees"
    try (claudeLine("a", at: "2026-09-25T12:00:00Z", cwd: "\(worktrees)/shop/w1/app", output: 100)
        + claudeLine("b", at: "2026-09-25T12:00:00Z", cwd: "\(worktrees)/blog/w2/app", output: 10))
        .write(to: dir.appendingPathComponent("1.jsonl"), atomically: true, encoding: .utf8)
    let url = dir.appendingPathComponent("db.sqlite")
    let store = try UsageStore(path: url)
    try await store.ingestClaude(roots: [dir])
    let db = try SQLiteDB(path: url.path)
    try db.exec("""
    DELETE FROM daily_usage WHERE output = 10;
    UPDATE daily_usage SET project = 'app', output = 110;
    DELETE FROM claude_message;
    """)
    try await store.repairWorktreeProjects(roots: [(dir, .claude)], hosts: [])
    #expect(try await store.daily(since: "2026-01-01").map(\.project) == ["app"])
}
