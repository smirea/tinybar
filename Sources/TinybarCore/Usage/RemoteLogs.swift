import Foundation
import os

/// Reads the Claude Code, Codex and Grok logs of `RemoteHosts` over SSH, without copying them, and
/// snapshots their Antigravity databases, which can't be read that way. A remote log's
/// path is `/@<host>/<path in the remote home>`, so its cursor never meets a local one.
enum RemoteLogs {
    static let prefix = "/@"
    private static let claudeRoots = [".claude/projects"]
    private static let codexRoots = [".codex/sessions", ".codex/archived_sessions"]
    /// A host that didn't answer is skipped for this long, so an offline one doesn't hold up each source
    /// with its own connect timeout.
    private static let retryAfter: TimeInterval = 60
    private static let downUntil = OSAllocatedUnfairLock(initialState: [String: Date]())
    // The `mini` entry in ~/.ssh/config opens an interactive shell; these make it run one command.
    // One shared connection per host keeps a read of each changed log cheap.
    private static let sshOptions = [
        "BatchMode=yes", "ConnectTimeout=5", "ServerAliveInterval=10", "ServerAliveCountMax=3",
        "RemoteCommand=none", "RequestTTY=no",
        "ControlMaster=auto", "ControlPath=/tmp/tinybar-ssh-%C", "ControlPersist=120",
    ].flatMap { ["-o", $0] }

    struct Failed: Error, CustomStringConvertible {
        var description: String
    }

    static func roots(_ source: UsageStore.LogSource) -> [URL] {
        RemoteHosts.all.flatMap { host in
            (source == .claude ? claudeRoots : codexRoots).map { URL(fileURLWithPath: "\(prefix)\(host)/\($0)", isDirectory: true) }
        }
    }

    static func isRemote(_ path: String) -> Bool {
        path.hasPrefix(prefix)
    }

    /// The `RemoteHosts` host a log is on, or `RemoteHosts.thisMac`.
    static func machine(of path: String) -> String {
        split(path)?.host ?? RemoteHosts.thisMac
    }

    /// Visits the `*.jsonl` files under a remote root like `UsageStore.walkJSONL`, skipping hidden folders.
    /// An unreachable host has no files.
    static func walk(_ root: String, _ visit: (String, UsageStore.FileStamp) throws -> Void) throws {
        guard let (host, dir) = split(root), isUp(host) else { return }
        let command = "find \(quote(dir)) -mindepth 1 -name '.*' -prune -o -type f -name '*.jsonl' -exec stat -f '%i %z %Fm %N' {} + 2>/dev/null; exit 0"
        guard let output = output(host, command) else {
            downUntil.withLock { $0[host] = Date().addingTimeInterval(retryAfter) }
            return
        }
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3)
            guard fields.count == 4, let inode = Int64(fields[0]), let size = Int64(fields[1]), let seconds = Double(fields[2]) else { continue }
            try visit("\(prefix)\(host)/\(fields[3])", UsageStore.FileStamp(inode: inode, size: size, mtime: Int64(seconds * 1000)))
        }
    }

    /// A remote log's bytes, from the one before `start` when `start > 0`, as `JSONLReader` reads it.
    /// Nil for a local path.
    static func open(_ path: String, from start: Int64) throws -> Stream? {
        guard let (host, file) = split(path) else { return nil }
        return try Stream(host: host, command: "tail -c +\(max(start, 1)) \(quote(file))")
    }

    final class Stream {
        /// The read end, owned by the caller, who closes it.
        let fd: Int32
        private let process: Process
        private let pipe = Pipe()

        fileprivate init(host: String, command: String) throws {
            process = RemoteLogs.ssh(host, command)
            process.standardOutput = pipe
            try process.run()
            fd = dup(pipe.fileHandleForReading.fileDescriptor)
            try? pipe.fileHandleForReading.close()
            guard fd >= 0 else {
                process.terminate()
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }

        /// After reading to the end: whether all of it came. Stopping early just ends the command.
        func finish(drained: Bool) throws {
            guard drained else { return cancel() }
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw Failed(description: "ssh \(process.arguments?.last ?? "") exited with \(process.terminationStatus)")
            }
        }

        func cancel() {
            if process.isRunning { process.terminate() }
        }
    }

    /// The Grok CLI's sessions folder on each host, read like its Claude Code logs.
    static func grokRoots() -> [(root: String, machine: String)] {
        RemoteHosts.all.map { ("\(prefix)\($0)/.grok/sessions", $0) }
    }

    struct RemoteDatabase {
        var path: String
        var stamp: UsageStore.FileStamp
        var wal: UsageStore.FileStamp?
    }

    /// Antigravity's conversation databases on `host`, found in the folders
    /// `AntigravityHistory.conversationRoots` searches here. Nil when the host doesn't answer.
    static func antigravityDatabases(_ host: String) -> [RemoteDatabase]? {
        guard isUp(host) else { return nil }
        let roots = ["antigravity", "antigravity-cli", "antigravity-ide", "antigravity-backup"].map { ".gemini/\($0)" }
            + [".config/antigravity", ".t3/userdata/providers/antigravity/*/antigravity-acp"]
        let command = """
        for r in \(roots.joined(separator: " ")); do [ -d "$r/conversations" ] && r="$r/conversations"; [ -d "$r" ] && \
        find -H "$r" -mindepth 1 -name '.*' -prune -o -type f \\( -name '*.db' -o -name '*.db-wal' \\) -exec stat -f '%i %z %Fm %N' {} +; \
        done 2>/dev/null; exit 0
        """
        guard let output = output(host, command) else {
            downUntil.withLock { $0[host] = Date().addingTimeInterval(retryAfter) }
            return nil
        }
        var databases: [String: UsageStore.FileStamp] = [:], wals: [String: UsageStore.FileStamp] = [:]
        var inodes = Set<Int64>()
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3)
            guard fields.count == 4, let inode = Int64(fields[0]), let size = Int64(fields[1]), let seconds = Double(fields[2]) else { continue }
            let path = String(fields[3]), stamp = UsageStore.FileStamp(inode: inode, size: size, mtime: Int64(seconds * 1000))
            if path.hasSuffix(".db-wal") {
                wals[String(path.dropLast(4))] = stamp
            } else if inodes.insert(inode).inserted {
                // One database reached through two roots, as a linked profile folder gives it.
                databases[path] = stamp
            }
        }
        return databases.sorted { $0.key < $1.key }.map { RemoteDatabase(path: "\(prefix)\(host)/\($0.key)", stamp: $0.value, wal: wals[$0.key]) }
    }

    /// Copies a database on its host to `local` as one consistent snapshot. `sqlite3 .backup` takes it
    /// there, so a write during the copy can't tear it, and it travels compressed: these shrink about
    /// sixfold. The source is opened read-only, so Antigravity's own files are never written.
    static func copyDatabase(_ path: String, to local: URL) throws {
        guard let (host, file) = split(path) else { throw Failed(description: "\(path) isn't remote") }
        // Without a WAL beside it, a WAL-mode database only opens read-only as immutable.
        let command = """
        f=\(quote(file)); if [ -e "$f-wal" ]; then m=mode=ro; else m=immutable=1; fi; \
        t=$(mktemp -t tinybar) || exit 1; sqlite3 "file:$f?$m" ".backup '$t'" && gzip -1 -c "$t"; s=$?; rm -f "$t"; exit $s
        """
        let ssh = ssh(host, command), gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzip.arguments = ["-c"]
        let pipe = Pipe()
        ssh.standardOutput = pipe
        gunzip.standardInput = pipe
        guard FileManager.default.createFile(atPath: local.path, contents: nil), let out = FileHandle(forWritingAtPath: local.path) else {
            throw Failed(description: "can't write \(local.path)")
        }
        defer { try? out.close() }
        gunzip.standardOutput = out
        gunzip.standardError = FileHandle.nullDevice
        try gunzip.run()
        do { try ssh.run() } catch {
            gunzip.terminate()
            throw error
        }
        let watchdog = DispatchWorkItem { if ssh.isRunning { ssh.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300, execute: watchdog)
        defer { watchdog.cancel() }
        ssh.waitUntilExit()
        gunzip.waitUntilExit()
        guard ssh.terminationStatus == 0, gunzip.terminationStatus == 0 else {
            throw Failed(description: "copying \(path) failed: ssh \(ssh.terminationStatus), gunzip \(gunzip.terminationStatus)")
        }
    }

    /// Whether `host` answers now, ignoring an earlier failure.
    static func isReachable(_ host: String) -> Bool {
        output(host, "exit 0") != nil
    }

    private static func isUp(_ host: String) -> Bool {
        downUntil.withLock { ($0[host] ?? .distantPast) < Date() }
    }

    private static func split(_ path: String) -> (host: String, path: String)? {
        guard isRemote(path) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return (String(rest[..<slash]), String(rest[rest.index(after: slash)...]))
    }

    private static func ssh(_ host: String, _ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshOptions + [host, command]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// What `command` printed on `host`, or nil if it didn't finish in a minute or ssh failed.
    private static func output(_ host: String, _ command: String) -> String? {
        let process = ssh(host, command)
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: watchdog)
        defer { watchdog.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
