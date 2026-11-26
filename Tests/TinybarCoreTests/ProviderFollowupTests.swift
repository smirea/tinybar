import Foundation
import SQLite3
@testable import TinybarCore
import Testing

@Test func cookieReadsDropExpiredRowsButKeepSessionCookies() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = root.appendingPathComponent("cookies.sqlite")
    var writer: OpaquePointer?
    #expect(sqlite3_open(db.path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    let chromiumNow: Int64 = (11_644_473_600 + 100) * 1_000_000
    let sql = """
    CREATE TABLE moz_cookies(host TEXT, name TEXT, value TEXT, expiry INTEGER);
    INSERT INTO moz_cookies VALUES ('claude.ai','old','synthetic',99),('claude.ai','boundary','synthetic',100),('claude.ai','valid','synthetic',101);
    CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER);
    INSERT INTO cookies VALUES ('claude.ai','old','synthetic',X'',\(chromiumNow - 1)),
      ('claude.ai','boundary','synthetic',X'',\(chromiumNow)),
      ('claude.ai','valid','synthetic',X'',\(chromiumNow + 1_000_000)),
      ('claude.ai','session','synthetic',X'',0);
    """
    #expect(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
    let now = Date(timeIntervalSince1970: 100)
    #expect(BrowserCookies.readRows(db: db, domain: "claude.ai", firefox: true, now: now)?.map(\.name) == ["valid"])
    #expect(BrowserCookies.readRows(db: db, domain: "claude.ai", firefox: false, now: now)?.map(\.name) == ["valid", "session"])
}

@Test func calendarInvalidTimestampsNeverBecomeValidGrantDates() throws {
    for raw in ["2026-02-31T00:00:00Z", "2026-02-29T00:00:00.123Z", "2100-02-29T00:00:00Z", "2026-04-31T00:00:00+01:00"] {
        #expect(parseUTCTimestamp(raw) == nil)
        #expect(parseISODate(raw) == nil)
    }
    for raw in ["2099-01-01T00:00:00Zgarbage", "2099-01-01T00:00:00.12345678901Zgarbage", "2099-01-01T00:00:00+01:99", "2099-01-01T00:00:00Z\n"] {
        #expect(parseUTCTimestamp(raw) == nil)
        #expect(parseISODate(raw) == nil)
    }
    #expect(parseISODate("2024-02-29T00:00:00Z") != nil)
    #expect(parseISODate("2000-02-29T00:00:00Z") != nil)
    #expect(parseISODate("2024-02-29T01:00:00+01:00") == parseISODate("2024-02-29T00:00:00Z"))
    let json = #"{"eligible":true,"grants":[{"resets_left":1,"paused":false,"ends_at":"2026-02-31T00:00:00Z"}]}"#
    let grants = try JSONDecoder().decode(ClaudeUsageAPI.ResetGrants.self, from: Data(json.utf8))
    #expect(grants.available(at: parseISODate("2026-03-01T00:00:00Z")!).isEmpty)
}

@Test func expiredCursorLoginRemainsDetectable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = root.appendingPathComponent("state.sqlite")
    var writer: OpaquePointer?
    #expect(sqlite3_open(db.path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    let payload = Data(#"{"sub":"auth0|fixture","exp":100}"#.utf8).base64EncodedString()
    let token = "header.\(payload).signature"
    #expect(sqlite3_exec(writer, "CREATE TABLE ItemTable(key TEXT, value TEXT)", nil, nil, nil) == SQLITE_OK)
    #expect(CursorAppAuth.storedAccessToken(db: db) == nil)
    #expect(sqlite3_exec(writer, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)')", nil, nil, nil) == SQLITE_OK)
    let stored = try #require(CursorAppAuth.storedAccessToken(db: db))
    #expect(stored == token)
    #expect(CursorAppAuth.accessToken(stored, now: Date(timeIntervalSince1970: 101)) == nil)
    #expect(CursorAppAuth.accessToken(stored, now: Date(timeIntervalSince1970: 0)) == token)
    #expect(sqlite3_exec(writer, "UPDATE ItemTable SET value = ''", nil, nil, nil) == SQLITE_OK)
    #expect(CursorAppAuth.storedAccessToken(db: db) == nil)
}

@Test func codexWindowIdsStayTheOnesPinsAndAlertsAreSavedUnder() throws {
    let rpcJSON = #"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300},"secondary":{"usedPercent":50,"windowDurationMins":10080}},"rateLimitsByLimitId":{"spark":{"primary":{"usedPercent":10,"windowDurationMins":300}},"named":{"limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":20,"windowDurationMins":300}}}}"#
    let rpc = CodexAppServer.snapshot(from: try JSONDecoder().decode(CodexAppServer.Response.self, from: Data(rpcJSON.utf8)))
    #expect(rpc.windows.map(\.id) == ["session", "weekly", "gpt-5-3-codex-spark-session", "spark-session"])
    #expect(rpc.windows.last?.isModelSpecific == true)
}
