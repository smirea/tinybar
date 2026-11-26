import Foundation

/// Where Claude Code keeps its login, only to tell whether there is one and whose it is. The token
/// itself is never read: limits come through the CLI (ADR 0016).
public enum ClaudeCredentials {
    static let keychainService = "Claude Code-credentials"

    /// The Keychain item of a login in another config folder. Claude Code names it with a hash of
    /// the `CLAUDE_CONFIG_DIR` it ran with; this isn't documented, so a change would hide the folder.
    static func keychainService(folder: URL?) -> String {
        guard let folder else { return keychainService }
        return "\(keychainService)-\(sha256Hex(folder.path.precomposedStringWithCanonicalMapping).prefix(8))"
    }

    /// With `folder`, a login in that config folder; without, the default login.
    public static func hasStoredLogin(folder: URL? = nil) -> Bool {
        if credentialFiles(folder: folder).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { return true }
        // Attribute-only lookup: never touches the secret, never prompts.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService(folder: folder)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func credentialFiles(folder: URL? = nil) -> [URL] {
        (folder.map { [$0] } ?? Paths.claudeConfigDirs()).map { $0.appendingPathComponent(".credentials.json") }
    }

    /// Who is signed in, from the `oauthAccount` Claude Code keeps beside its settings. nil when it
    /// can't be told.
    public static func identity(folder: URL? = nil, env: [String: String] = ProcessInfo.processInfo.environment) -> LoginIdentity? {
        // The folder Claude Code reads its login from, so limits are filed under whose they are.
        let dirs = folder.map { [$0] } ?? Paths.claudeConfigDirs(env: env)
        let configHome = dirs.first { FileManager.default.isReadableFile(atPath: $0.appendingPathComponent(".credentials.json").path) } ?? dirs[0]
        let base = folder ?? (env["CLAUDE_CONFIG_DIR"]?.isEmpty == false ? configHome : Paths.home)
        // An older config file wins while it holds anything, as it does in Claude Code.
        let legacy = configHome.appendingPathComponent(".config.json")
        let size = (try? legacy.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let file = size > 0 ? legacy : base.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return identity(fromConfig: data)
    }

    static func identity(fromConfig data: Data) -> LoginIdentity? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let email = (account["emailAddress"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty
        else { return nil }
        return LoginIdentity(
            email: email,
            organization: account["organizationUuid"] as? String,
            organizationName: account["organizationName"] as? String)
    }
}
