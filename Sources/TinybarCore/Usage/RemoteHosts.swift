/// Machines whose Claude Code, Codex, Grok and Antigravity usage counts as if it ran here, read over `ssh <host>`.
/// Each is a host from ~/.ssh/config that connects without a prompt.
public enum RemoteHosts {
    public static let all = ["mini"]
    /// The machine of usage read from this Mac's own logs.
    public static let thisMac = ""

    public static func displayName(_ machine: String) -> String {
        machine == thisMac ? "This Mac" : machine
    }
}
