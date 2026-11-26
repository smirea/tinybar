import Foundation

/// A short-lived `codex app-server` (sandboxed read-only, no approvals), asked one JSON-RPC
/// question and then terminated. Lets the CLI use and refresh its own login: the fallback source
/// for limits, and the only way Tinybar uses a Banked Reset (ADR 0014).
enum CodexAppServer {
    struct Response: Decodable {
        var rateLimits: Snapshot
        var rateLimitsByLimitId: [String: Snapshot]?
        var rateLimitResetCredits: ResetCredits?
    }

    struct Snapshot: Decodable {
        var limitId: String?
        var limitName: String?
        var primary: Window?
        var secondary: Window?
        var credits: CreditsWire?
        var planType: String?
    }

    struct Window: Decodable {
        var usedPercent: Double
        var windowDurationMins: Int?
        var resetsAt: Int?
    }

    struct CreditsWire: Decodable {
        var hasCredits: Bool
        var unlimited: Bool
        var balance: String?
    }

    struct ResetCredits: Decodable {
        var credits: [ResetCredit]
    }

    struct ResetCredit: Decodable {
        var id: String
        var status: String
        var expiresAt: Int?
        var title: String?
    }

    static func fetch(home: URL? = nil, timeout: TimeInterval = 15) async throws -> ProviderSnapshot {
        try await snapshot(from: call("account/rateLimits/read", params: [:], home: home, executable: locateCodex(), timeout: timeout))
    }

    private struct ConsumeResponse: Decodable {
        var outcome: BankedResetOutcome
    }

    /// `attempt` identifies one press of the button, so a retried request can't use a second reset.
    static func useBankedReset(
        home: URL?, attempt: UUID, executable: String? = locateCodex(), timeout: TimeInterval = 30) async throws -> BankedResetOutcome
    {
        let response: ConsumeResponse = try await call(
            "account/rateLimitResetCredit/consume", params: ["idempotencyKey": attempt.uuidString],
            home: home, executable: executable, timeout: timeout)
        return response.outcome
    }

    private static func call<T: Decodable>(
        _ method: String, params: [String: String], home: URL?, executable: String?, timeout: TimeInterval) async throws -> T
    {
        guard let executable else { throw ProviderError.notConfigured }
        let data = try await Task.detached(priority: .userInitiated) {
            try runRPC(executable: executable, method: method, params: params, home: home, timeout: timeout)
        }.value
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ProviderError.unexpected("Unexpected codex app-server response")
        }
    }

    static func snapshot(from r: Response, now: Date = Date()) -> ProviderSnapshot {
        var windows: [LimitWindow] = []
        var seen = Set<String>()
        let main = r.rateLimits
        let extras = (r.rateLimitsByLimitId ?? [:])
            .filter { $0.key != (main.limitId ?? "codex") }
            .sorted { $0.key < $1.key }
        for (snapshot, isExtra, key) in [(main, false, "codex")] + extras.map({ ($0.value, true, $0.key) }) {
            let name = isExtra ? (snapshot.limitName ?? snapshot.limitId ?? key) : nil
            let prefix = name.map(CodexUsageAPI.slugify)
            for (w, fallbackID) in [(snapshot.primary, "primary"), (snapshot.secondary, "secondary")] {
                guard let w else { continue }
                let seconds = w.windowDurationMins.flatMap { minutes -> Int? in
                    let (seconds, overflow) = minutes.multipliedReportingOverflow(by: 60)
                    return overflow || seconds <= 0 ? nil : seconds
                }
                let base = WindowKind(durationSeconds: seconds).idComponent ?? fallbackID
                let id = prefix.map { "\($0)-\(base)" } ?? base
                guard seen.insert(id).inserted else { continue }
                let title = WindowKind.title(durationSeconds: seconds)
                windows.append(LimitWindow(
                    id: id,
                    title: name.map { "\($0) \(title)" } ?? title,
                    usedPercent: min(max(w.usedPercent, 0), 100),
                    resetsAt: w.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    durationSeconds: seconds,
                    isModelSpecific: isExtra))
            }
        }
        let credits = main.credits.map {
            Credits(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance.flatMap(Double.init))
        }
        let banked = r.rateLimitResetCredits?.credits.map {
            BankedReset(
                id: $0.id, title: $0.title, status: $0.status,
                expiresAt: $0.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
        return ProviderSnapshot(
            provider: .codex,
            plan: main.planType.map(CodexUsageAPI.formatPlan),
            windows: windows,
            credits: credits,
            bankedResets: banked,
            source: .cliProcess,
            fetchedAt: now)
    }

    // MARK: Process

    static func locateCodex() -> String? {
        let fm = FileManager.default
        let candidates = Paths.cliDirectories().map { "\($0)/codex" } + [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// The `result` of one request, as JSON.
    static func runRPC(
        executable: String, method: String, params: [String: String], home: URL?, timeout: TimeInterval) throws -> Data
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        var env = ProcessInfo.processInfo.environment
        // GUI apps get a minimal PATH; the npm- or bun-installed CLI is a node script.
        env["PATH"] = (Paths.cliDirectories() + ["/usr/bin", "/bin", env["PATH"] ?? ""]).joined(separator: ":")
        if let home { env["CODEX_HOME"] = home.path }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ProviderError.unexpected("Could not prepare codex input")
        }

        do { try process.run() } catch { throw ProviderError.unexpected("Could not launch codex: \(error.localizedDescription)") }
        // Process creates its own group on macOS; include the npm launcher's native child.
        let pid = process.processIdentifier
        let target = getpgid(pid) == pid ? -pid : pid
        defer {
            try? stdin.fileHandleForWriting.close()
            kill(target, SIGKILL)
            process.waitUntilExit()
        }

        // SIGTERM can be ignored; kill the group so inherited stdout handles close too.
        let watchdog = DispatchWorkItem { kill(target, SIGKILL) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            do { try stdin.fileHandleForWriting.write(contentsOf: data) }
            catch { throw ProviderError.unexpected("codex app-server closed its input") }
        }

        var reader = LineReader(handle: stdout.fileHandleForReading)
        func response(id: Int) throws -> [String: Any] {
            while let line = try reader.next() {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (obj["id"] as? NSNumber)?.intValue == id
                else { continue }
                if obj["error"] is [String: Any] {
                    // CLI errors can include upstream response bodies or credential details.
                    throw ProviderError.unexpected("codex app-server request failed")
                }
                return obj
            }
            throw ProviderError.unexpected("codex app-server exited without answering")
        }

        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tinybar", "version": "0.1.0"]]])
        _ = try response(id: 1)
        try send(["method": "initialized", "params": [String: Any]()])
        try send(["id": 2, "method": method, "params": params])
        let message = try response(id: 2)
        guard let result = message["result"] as? [String: Any] else { throw ProviderError.unexpected("codex app-server: no result") }
        return try JSONSerialization.data(withJSONObject: result)
    }
}

/// Minimal blocking newline reader over a pipe.
struct LineReader {
    let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) { self.handle = handle }

    mutating func next() throws -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(chunk)
            guard buffer.count <= 1 << 20 else { throw ProviderError.unexpected("codex app-server response is too large") }
        }
    }
}
