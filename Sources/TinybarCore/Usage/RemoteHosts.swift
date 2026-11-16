/// Machines whose Claude Code and Codex logs count as if they ran here, read over `ssh <host>`.
/// Each is a host from ~/.ssh/config that connects without a prompt.
public enum RemoteHosts {
    public static let all = ["mini"]
}
