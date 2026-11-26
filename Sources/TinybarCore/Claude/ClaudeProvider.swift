import Foundation

/// Claude limits, read only through Claude Code itself (SPEC §4, ADR 0016). With `folder`, the login
/// in that config folder (SPEC §15).
public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude
    private let folder: URL?

    public init(folder: URL? = nil) {
        self.folder = folder
    }

    public func isConfigured() -> Bool {
        ClaudeCredentials.hasStoredLogin(folder: folder)
    }

    public func identity() -> LoginIdentity? {
        ClaudeCredentials.identity(folder: folder)
    }

    public func fetch() async throws -> ProviderSnapshot {
        try await ClaudeCLIUsage.fetch(folder: folder)
    }
}
