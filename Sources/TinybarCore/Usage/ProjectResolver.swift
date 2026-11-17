import Foundation

/// Maps a working directory to its Project: the git repository containing it (CONTEXT.md).
///
/// - Worktrees (a `.git` *file* pointing at `<repo>/.git/worktrees/<name>`) resolve to the main repo.
/// - A coding agent's worktree folder (`AgentWorktree`) that no longer exists is named by its repo.
/// - A directory that no longer exists, with no repository above it, is named by its last path component.
/// - Anything else outside a repository has no Project.
public final class ProjectResolver: @unchecked Sendable {
    public static let noProject = ""

    private var cache: [String: String] = [:]
    private let lock = NSLock()
    private let fm = FileManager.default

    public init() {}

    /// Returns the Project key (repo root path), a bare name for deleted paths, or `noProject`.
    public func project(for cwd: String?) -> String {
        guard let cwd, cwd.hasPrefix("/") else { return Self.noProject }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[cwd] { return hit }
        let resolved = resolve(cwd)
        cache[cwd] = resolved
        return resolved
    }

    public static func displayName(_ project: String) -> String {
        project.isEmpty ? "No project" : (project as NSString).lastPathComponent
    }

    /// What this resolver filed a missing directory under before it knew `AgentWorktree` layouts:
    /// its last path component. Nil where that never applied.
    func legacyName(for cwd: String) -> String? {
        guard cwd.hasPrefix("/"), !project(for: cwd).hasPrefix("/") else { return nil }
        let standardized = (cwd as NSString).standardizingPath
        return fm.fileExists(atPath: standardized) ? nil : (standardized as NSString).lastPathComponent
    }

    private func resolve(_ cwd: String) -> String {
        let standardized = (cwd as NSString).standardizingPath
        let worktree = AgentWorktree(standardized)
        var dir = standardized
        // An agent's worktree is never inside the repo it checks out, so a repository found above it is unrelated.
        while dir != "/" && !dir.isEmpty && dir != worktree?.parent {
            if let cached = cache[dir], cached.hasPrefix("/") { return cached }
            let git = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDir) {
                let root = isDir.boolValue ? dir : (mainRepo(fromGitFile: git) ?? dir)
                cache[dir] = root
                return root
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if let worktree { return worktree.repo ?? Self.noProject }
        if !fm.fileExists(atPath: standardized) {
            return (standardized as NSString).lastPathComponent
        }
        return Self.noProject
    }

    /// `gitdir: /repo/.git/worktrees/name` → `/repo`. Submodules (`.git/modules/…`) keep their own dir.
    private func mainRepo(fromGitFile path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") {
            gitdir = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(gitdir)
        }
        gitdir = (gitdir as NSString).standardizingPath
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<range.lowerBound])
    }
}

/// Where coding agents put the throwaway checkouts they work in, which they delete when done. The
/// folder of a deleted one names the repo it checked out, while its own name is an id.
struct AgentWorktree {
    /// The folder holding the checkout, where looking for its repository stops.
    let parent: String
    /// The repository's folder name; nil for a scratch folder with no repository.
    let repo: String?

    init?(_ path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        func index(_ a: String, _ b: String) -> Int? {
            parts.indices.dropLast().first { parts[$0] == a && parts[$0 + 1] == b }
        }
        func prefix(_ n: Int) -> String { "/" + parts.prefix(n).joined(separator: "/") }
        if let i = index(".t3", "worktrees"), parts.count > i + 3 {
            // T3 Code: ~/.t3/worktrees/<repo>/<id>
            parent = prefix(i + 3)
            repo = parts[i + 2]
        } else if let i = index(".codex", "worktrees"), parts.count > i + 3 {
            // Codex: ~/.codex/worktrees/<id>/<repo>
            parent = prefix(i + 3)
            repo = parts[i + 3]
        } else if let i = index(".t3", "scratch"), parts.count > i + 2 {
            parent = prefix(i + 2)
            repo = nil
        } else {
            return nil
        }
    }
}
