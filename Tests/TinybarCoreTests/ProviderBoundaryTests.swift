import Foundation
import SQLite3
@testable import TinybarCore
import Testing

private final class RedirectFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        if url.path == "/finish" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("finished".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let target = switch url.path {
        case "/host": "https://other.invalid/finish"
        case "/scheme": "http://origin.invalid/finish"
        case "/port": "https://origin.invalid:8443/finish"
        default: "https://origin.invalid/finish"
        }
        var next = request
        next.url = URL(string: target)!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target])!
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Test func credentialsNeverFollowCrossOriginRedirects() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RedirectFixture.self]
    config.timeoutIntervalForRequest = 2
    config.timeoutIntervalForResource = 5
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    for header in ["Cookie", "Authorization"] {
        for path in ["host", "scheme", "port"] {
            var request = URLRequest(url: URL(string: "https://origin.invalid/\(path)")!)
            request.setValue("synthetic", forHTTPHeaderField: header)
            do {
                _ = try await HTTP.send(request, session: session, providerName: "Fixture")
                Issue.record("Credential-bearing \(header) request followed \(path) redirect")
            } catch let error as ProviderError {
                #expect(error == .unexpected("Fixture API returned HTTP 302"))
            }
        }
    }
    for (path, authenticated) in [("host", false), ("scheme", false), ("port", false), ("same", true)] {
        var request = URLRequest(url: URL(string: "https://origin.invalid/\(path)")!)
        if authenticated { request.setValue("synthetic", forHTTPHeaderField: "Cookie") }
        #expect(try await HTTP.send(request, session: session, providerName: "Fixture") == Data("finished".utf8))
    }
}

@Test func cookieAndCursorReadsSeeWALWithoutChangingOriginalFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = root.appendingPathComponent("cookies.sqlite")
    var writer: OpaquePointer?
    #expect(sqlite3_open(db.path, &writer) == SQLITE_OK)
    defer { sqlite3_close(writer) }
    func execute(_ sql: String) throws {
        #expect(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK)
    }
    try execute("PRAGMA journal_mode=WAL; CREATE TABLE moz_cookies(host TEXT, name TEXT, value TEXT, expiry INTEGER DEFAULT 4102444800); CREATE TABLE ItemTable(key TEXT, value TEXT); CREATE TABLE meta(key TEXT, value TEXT)")
    try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    try execute("INSERT INTO moz_cookies(host, name, value) VALUES ('claude.ai', 'sessionKey', 'synthetic'); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'synthetic'); INSERT INTO meta VALUES ('version', '24')")

    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    let contents = try files.map { try Data(contentsOf: $0) }
    let mtimes = try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    #expect(BrowserCookies.readRows(db: db, domain: "claude.ai", firefox: true)?.map(\.value) == ["synthetic"])
    #expect(BrowserCookies.metaVersion(db: db) == 24)
    #expect(CursorAppAuth.readItem("cursorAuth/accessToken", db: db) == "synthetic")
    #expect(Set(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) == Set(files))
    #expect(try files.map { try Data(contentsOf: $0) } == contents)
    #expect(try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } == mtimes)

    var temporary: URL?
    let _: Int? = CredentialDatabase.read(db) { handle in
        let path = String(cString: sqlite3_db_filename(handle, "main"))
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        temporary = directory
        #expect(directory != root)
        #expect((try? FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int) == 0o700)
        return nil // Failed reads must clean up too.
    }
    #expect(temporary != nil)
    #expect(!FileManager.default.fileExists(atPath: temporary!.path))
}

@Test func retryAfterAcceptsSecondsAndHTTPDates() {
    let now = parseISODate("2026-10-19T12:00:00Z")!
    #expect(HTTP.retryAfter("3600", now: now) == 3600)
    #expect(HTTP.retryAfter("Mon, 19 Oct 2026 13:00:00 GMT", now: now) == 3600)
    #expect(HTTP.retryAfter("Mon, 19 Oct 2026 11:00:00 GMT", now: now) == 0)
    #expect(HTTP.retryAfter("invalid", now: now) == nil)
    #expect(HTTP.retryAfter("nan", now: now) == nil)
}

@Test func deniedBrowserKeyIsNotRequestedAgain() {
    let browser = BrowserCookies.Browser(name: "Fixture", root: "unused", keychainService: UUID().uuidString, keychainAccount: "fixture")
    var calls = 0
    for _ in 0..<3 {
        #expect(BrowserCookies.key(for: browser) { _, _ in calls += 1; return nil } == nil)
    }
    #expect(calls == 1)
}

@Test func malformedResetGrantsDoNotCountOrOverflow() throws {
    func grants(_ body: String) throws -> [BankedReset] {
        let response = try JSONDecoder().decode(ClaudeUsageAPI.ResetGrants.self, from: Data("{\"eligible\":true,\"grants\":[\(body)]}".utf8))
        return response.available(at: Date())
    }
    #expect(try grants(#"{"resets_left":1,"paused":false,"ends_at":"invalid"},{"resets_left":1,"paused":false,"starts_at":"invalid"}"#).isEmpty)
    #expect(try grants("{\"resets_left\":1,\"paused\":false},{\"resets_left\":\(Int.max),\"paused\":false}").isEmpty)
    #expect(try grants(#"{"resets_left":1,"paused":false}"#).count == 1)
    // A malformed label is dropped, not the reset.
    #expect(try grants(#"{"label":42,"resets_left":1,"paused":false}"#).map(\.title) == [nil])
}

@Test func codexDurationCannotOverflow() throws {
    let json = "{\"rateLimits\":{\"primary\":{\"usedPercent\":25,\"windowDurationMins\":\(Int.max)}}}"
    let response = try JSONDecoder().decode(CodexAppServer.Response.self, from: Data(json.utf8))
    let snapshot = CodexAppServer.snapshot(from: response)
    #expect(snapshot.windows.first?.remainingPercent == 75)
    #expect(snapshot.windows.first?.durationSeconds == nil)
}

private func withCLI(_ body: String, test: (String, URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("cli")
    let pidFile = root.appendingPathComponent("pid")
    try "#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile.path)'\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    try await test(script.path, pidFile)
}

private func readLimits(_ executable: String, timeout: TimeInterval) throws -> Data {
    try CodexAppServer.runRPC(executable: executable, method: "account/rateLimits/read", params: [:], home: nil, timeout: timeout)
}

@Suite(.serialized)
struct ProviderProcessTests {
    @Test func providerProcessesCannotIgnoreTheirDeadline() async throws {
        // A finite sleep bounds the test itself even if the production watchdog regresses.
        for codex in [true, false] {
            try await withCLI("/bin/sleep 4") { executable, pidFile in
                let start = Date()
                #expect(throws: ProviderError.self) {
                    if codex { _ = try readLimits(executable, timeout: 1) }
                    else { _ = try AntigravityCLI.runUsage(executable: executable, timeout: 1) }
                }
                #expect(Date().timeIntervalSince(start) < 3)
                let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                #expect(kill(pid, 0) == -1)
            }
        }
    }

    @Test func codexReapsChildAfterSuccessfulRPC() async throws {
        try await withCLI("""
        read initialize
        printf '%s\\n' '{"id":1,"result":{}}'
        read initialized
        read account
        printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
        read limits
        printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":25}}}}'
        /bin/sleep 2
        """) { executable, pidFile in
            let response = try JSONDecoder().decode(CodexAppServer.Response.self, from: readLimits(executable, timeout: 5))
            #expect(response.rateLimits.primary?.usedPercent == 25)
            let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(kill(pid, 0) == -1)
        }
    }

    @Test func codexClosedInputDoesNotSignalTheApp() async throws {
        try await withCLI("""
        read initialize
        exec 0<&-
        printf '%s\\n' '{"id":1,"result":{}}'
        /bin/sleep 2
        """) { executable, _ in
            #expect(throws: ProviderError.unexpected("codex app-server closed its input")) {
                try readLimits(executable, timeout: 5)
            }
        }
    }

    @Test func codexRejectsNonObjectRPCResults() async throws {
        for result in ["null", "42", "[]"] {
            try await withCLI("""
            read initialize
            printf '%s\\n' '{"id":1,"result":{}}'
            read initialized
            read account
            printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
            read limits
            printf '%s\\n' '{"id":3,"result":\(result)}'
            """) { executable, _ in
                #expect(throws: ProviderError.unexpected("codex app-server: no result")) {
                    try readLimits(executable, timeout: 5)
                }
            }
        }
    }

    @Test func aCodexCLIWithNoAccountIsAnExpiredLogin() async throws {
        try await withCLI("""
        read initialize
        printf '%s\\n' '{"id":1,"result":{}}'
        read initialized
        read account
        printf '%s\\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
        """) { executable, _ in
            #expect(throws: ProviderError.loginExpired) { try readLimits(executable, timeout: 5) }
        }
    }

    @Test func codexBoundsOutputAndRedactsRPCFailures() async throws {
        try await withCLI("/usr/bin/head -c 1100000 /dev/zero") { executable, _ in
            #expect(throws: ProviderError.unexpected("codex app-server response is too large")) {
                try readLimits(executable, timeout: 5)
            }
        }
        try await withCLI("read initialize; printf '%s\\n' '{\"id\":1,\"error\":{\"message\":\"Bearer synthetic-secret\"}}'") { executable, _ in
            #expect(throws: ProviderError.unexpected("codex app-server request failed")) {
                try readLimits(executable, timeout: 5)
            }
        }
    }

    @Test func codexUsesABankedResetThroughTheLoginsOwnFolder() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")
        let seen = FileManager.default.temporaryDirectory.appendingPathComponent("codex-seen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: seen) }
        try await withCLI("""
        read initialize
        printf '%s\\n' '{"id":1,"result":{}}'
        read initialized
        read account
        printf '%s\\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
        read consume
        printf '%s\\n%s\\n' "$CODEX_HOME" "$consume" > '\(seen.path)'
        printf '%s\\n' '{"id":3,"result":{"outcome":"nothingToReset"}}'
        """) { executable, _ in
            let attempt = UUID()
            let outcome = try await CodexAppServer.useBankedReset(home: home, attempt: attempt, executable: executable, timeout: 5)
            #expect(outcome == .nothingToReset)
            let lines = try String(contentsOf: seen, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(lines.first == home.path)
            let request = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
            #expect(request["method"] as? String == "account/rateLimitResetCredit/consume")
            #expect((request["params"] as? [String: String]) == ["idempotencyKey": attempt.uuidString])
        }
    }
}
