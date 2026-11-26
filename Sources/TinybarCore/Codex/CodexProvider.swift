import Foundation

/// Codex limits. Source order (SPEC §4): CLI OAuth → `codex app-server` → chatgpt.com
/// browser session (opt-in). With `home`, only the login in that `CODEX_HOME` (SPEC §15).
public struct CodexProvider: UsageProvider {
    public let id = ProviderID.codex
    private let session: URLSession
    private let allowBrowser: @Sendable () -> Bool
    private let home: URL?

    public init(session: URLSession = .tinybar, home: URL? = nil, allowBrowser: @escaping @Sendable () -> Bool = { false }) {
        self.session = session
        self.home = home
        self.allowBrowser = allowBrowser
    }

    private var authFile: URL {
        home?.appendingPathComponent("auth.json") ?? CodexCredentials.authFileURL()
    }

    public func isConfigured() -> Bool {
        FileManager.default.fileExists(atPath: authFile.path)
    }

    public func identity() -> LoginIdentity? {
        CodexCredentials.identity(from: authFile)
    }

    public func fetch() async throws -> ProviderSnapshot {
        var lastError: ProviderError
        do {
            return try await fetch(with: CodexCredentials.load(from: authFile), source: .cli)
        } catch let error as ProviderError {
            // Only a login problem is worth a fallback; rate limits and network errors would
            // hit the same backend again.
            guard error == .loginExpired || error == .notConfigured else { throw error }
            lastError = error
        }

        // The CLI renews its own login while answering, and later checks read the renewed one.
        if CodexAppServer.locateCodex() != nil, let snapshot = try? await CodexAppServer.fetch(home: home) {
            return snapshot
        }
        if home != nil { throw lastError }

        if allowBrowser(),
           let found = BrowserCookies.find(domain: "chatgpt.com", required: [ChatGPTWebSession.cookieName])
        {
            do {
                let creds = try await ChatGPTWebSession.accessToken(cookies: found.cookies, session: session)
                return try await fetch(with: creds, source: .browser)
            } catch let error as ProviderError {
                lastError = error
            }
        }
        throw lastError
    }

    /// Asks the Codex CLI to use one of this login's Banked Resets (ADR 0014).
    public func useBankedReset(attempt: UUID = UUID()) async throws -> BankedResetOutcome {
        try await CodexAppServer.useBankedReset(home: home, attempt: attempt)
    }

    private func fetch(with creds: CodexCredentials, source: DataSource) async throws -> ProviderSnapshot {
        async let usage = CodexUsageAPI.fetchUsage(creds, session: session)
        async let banked = try? CodexUsageAPI.fetchBankedResets(creds, session: session)
        var snapshot = try await CodexUsageAPI.snapshot(from: usage, bankedResets: banked)
        snapshot.source = source
        return snapshot
    }
}

extension URLSession {
    /// Ephemeral: no cookie jar, no URL cache on disk.
    public static let tinybar: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
