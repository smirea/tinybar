import Foundation

/// Claude limits. Source order (SPEC §4): Claude Code's OAuth login → claude.ai browser
/// session (opt-in). With `folder`, only the login in that config folder (SPEC §15).
public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude
    private let session: URLSession
    private let allowBrowser: @Sendable () -> Bool
    private let folder: URL?

    public init(session: URLSession = .tinybar, folder: URL? = nil, allowBrowser: @escaping @Sendable () -> Bool = { false }) {
        self.session = session
        self.folder = folder
        self.allowBrowser = allowBrowser
    }

    public func isConfigured() -> Bool {
        ClaudeCredentials.hasStoredLogin(folder: folder)
    }

    public func identity() -> LoginIdentity? {
        ClaudeCredentials.identity(folder: folder)
    }

    public func fetch() async throws -> ProviderSnapshot {
        do {
            let creds = try ClaudeCredentials.load(folder: folder)
            do {
                guard !creds.isExpired else { throw ProviderError.loginExpired }
                let usage = try await ClaudeUsageAPI.fetchUsage(accessToken: creds.accessToken, session: session)
                return ClaudeUsageAPI.snapshot(from: usage, plan: creds.planName)
            } catch ProviderError.loginExpired {
                // Claude Code renews its own login while answering (ADR 0016); later checks then
                // read the renewed token directly.
                let usage = try await ClaudeCLIUsage.fetch(folder: folder)
                var snapshot = ClaudeUsageAPI.snapshot(from: usage, plan: (try? ClaudeCredentials.load(folder: folder))?.planName ?? creds.planName)
                snapshot.source = .cliProcess
                return snapshot
            }
        } catch let error as ProviderError {
            guard folder == nil, error == .loginExpired || error == .notConfigured, allowBrowser() else { throw error }
            guard let found = BrowserCookies.find(domain: "claude.ai", required: ["sessionKey"]),
                  let key = found.cookies["sessionKey"]
            else { throw error }
            return try await ClaudeWebAPI.fetch(sessionKey: key, session: session)
        }
    }
}
