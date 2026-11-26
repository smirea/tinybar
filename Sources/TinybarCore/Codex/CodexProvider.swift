import Foundation

/// Codex limits, read only through `codex app-server` (SPEC §4, ADR 0016). With `home`, the login
/// in that `CODEX_HOME` (SPEC §15).
public struct CodexProvider: UsageProvider {
    public let id = ProviderID.codex
    private let home: URL?

    public init(home: URL? = nil) {
        self.home = home
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
        try await CodexAppServer.fetch(home: home)
    }

    /// Asks the Codex CLI to use one of this login's Banked Resets (ADR 0014).
    public func useBankedReset(attempt: UUID = UUID()) async throws -> BankedResetOutcome {
        try await CodexAppServer.useBankedReset(home: home, attempt: attempt)
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
