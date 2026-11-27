import Foundation
@testable import TinybarCore
import Testing

private let turn = #"{"timestamp":1794060510,"method":"_x.ai/session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":1000,"outputTokens":300,"cachedReadTokens":600,"cacheCreationTokens":100,"reasoningTokens":250,"costUsdTicks":30000000000,"modelUsage":{"grok-4.7-build-fast":{"inputTokens":1000,"outputTokens":300,"cachedReadTokens":600,"cacheCreationTokens":100,"costUsdTicks":30000000000}}}},"_meta":{"agentTimestampMs":1794060510284}}}"#

@Test func grokInputIncludesItsCachedTokensAndOutputItsReasoning() throws {
    let records = GrokHistory.records(line: Data(turn.utf8), cwd: "/repo")
    let r = try #require(records.first)
    #expect(records.count == 1)
    #expect(r.model == "grok-4.7-build-fast")
    #expect(r.tokens == TokenCounts(input: 300, output: 300, cacheWrite: 100, cacheRead: 600))
    #expect(r.cost == 3)
}

/// A Grok sessions folder holding `turn` once, under `name` in a temporary folder.
private func grokSessions(_ root: URL, _ name: String) throws -> String {
    let session = root.appendingPathComponent("\(name)/%2Frepo/s1", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    try Data((turn + "\n").utf8).write(to: session.appendingPathComponent("updates.jsonl"))
    return root.appendingPathComponent(name).path
}

@Test func aGrokTurnReadAgainCountsOnceAndKeepsTheCLIsCost() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try UsageStore(path: root.appendingPathComponent("usage.sqlite"))
    let here = try grokSessions(root, "sessions")

    #expect(try await store.ingestForkHistory(grokRoots: [(here, RemoteHosts.thisMac)], antigravityRoots: [], antigravityHosts: []) == 1)
    // The same turn copied to another machine is the same response, and stays with the first.
    let there = try grokSessions(root, "mini-sessions")
    #expect(try await store.ingestForkHistory(
        grokRoots: [(here, RemoteHosts.thisMac), (there, "mini")], antigravityRoots: [], antigravityHosts: []) == 0)

    let rows = try await store.daily(since: "2000-01-01", provider: .grok)
    #expect(rows.map(\.tokens.total) == [1300])
    #expect(rows.map(\.machine) == [RemoteHosts.thisMac])
    #expect(rows.first.flatMap(PriceTable.empty.cost) == 3)
}

@Test func aGrokTurnFromAnotherMachineCountsUnderItWithTheCLIsCost() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try UsageStore(path: root.appendingPathComponent("usage.sqlite"))
    let there = try grokSessions(root, "sessions")

    #expect(try await store.ingestForkHistory(grokRoots: [(there, "mini")], antigravityRoots: [], antigravityHosts: []) == 1)
    let rows = try await store.daily(since: "2000-01-01", provider: .grok)
    #expect(rows.map(\.machine) == ["mini"])
    #expect(rows.first.flatMap(PriceTable.empty.cost) == 3)
}

@Test func antigravityPricesEachModelFromItsMakersTable() throws {
    let json = #"""
    {"anthropic":{"models":{"claude-sonnet-4-6":{"cost":{"input":3,"output":15}}}},
     "google":{"models":{"gemini-3.1-pro-preview":{"cost":{"input":2,"output":12}},"gemini-4-neon":{"cost":{"input":3,"output":15}}}}}
    """#
    let table = try PriceTable.parse(Data(json.utf8), fetchedAt: nil)
    #expect(table.price(provider: .gemini, model: "claude-sonnet-4-6")?.input == 3)
    #expect(table.price(provider: .gemini, model: "gemini-3.1-pro")?.output == 12)
    #expect(table.price(provider: .gemini, model: "gemini-4-neon")?.output == 15)
    #expect(table.price(provider: .gemini, model: "gemini-4-argon-trial") == nil)
}
