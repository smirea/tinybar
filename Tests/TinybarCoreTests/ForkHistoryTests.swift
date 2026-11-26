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

@Test func aGrokTurnReadAgainCountsOnceAndKeepsTheCLIsCost() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("sessions/%2Frepo/s1", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let file = session.appendingPathComponent("updates.jsonl")
    try Data((turn + "\n").utf8).write(to: file)
    let store = try UsageStore(path: root.appendingPathComponent("usage.sqlite"))
    let sessions = root.appendingPathComponent("sessions")

    #expect(try await store.ingestForkHistory(grokRoot: sessions, antigravityRoots: []) == 1)
    // The same turn in a second file, as a copied session leaves it, is the same response.
    let copy = root.appendingPathComponent("sessions/%2Frepo/s1-copy", isDirectory: true)
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    try Data((turn + "\n").utf8).write(to: copy.appendingPathComponent("updates.jsonl"))
    #expect(try await store.ingestForkHistory(grokRoot: sessions, antigravityRoots: []) == 0)

    let rows = try await store.daily(since: "2000-01-01", provider: .grok)
    #expect(rows.map(\.tokens.total) == [1300])
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
