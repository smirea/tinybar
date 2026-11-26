import Foundation

/// A short-lived `claude` in its SDK mode (stream-json over stdio), asked for usage and then killed,
/// as T3 Code reads Claude limits (ADR 0016). Claude Code settles its own login before it reads
/// usage, refreshing and saving an expired one, so Tinybar never touches a token. No prompt is ever
/// sent, so nothing reaches a model.
enum ClaudeCLIUsage {
    private struct Initialize: Decodable {
        var account: Account?

        struct Account: Decodable {
            var subscriptionType: String?
        }
    }

    private struct Usage: Decodable {
        var rateLimitsAvailable: Bool?
        var rateLimits: ClaudeUsageAPI.UsageResponse?

        enum CodingKeys: String, CodingKey {
            case rateLimitsAvailable = "rate_limits_available"
            case rateLimits = "rate_limits"
        }
    }

    static func fetch(folder: URL?, timeout: TimeInterval = 30) async throws -> ProviderSnapshot {
        guard let executable = Paths.locateCLI("claude") else { throw ProviderError.notConfigured }
        let (initData, usageData) = try await Task.detached(priority: .userInitiated) {
            try readUsage(executable: executable, folder: folder, timeout: timeout)
        }.value
        guard let usage = try? JSONDecoder().decode(Usage.self, from: usageData) else {
            throw ProviderError.unexpected("Unexpected Claude Code usage response")
        }
        // Without rate limits the CLI isn't signed in to a subscription it can read limits for.
        guard usage.rateLimitsAvailable == true, let limits = usage.rateLimits else { throw ProviderError.loginExpired }
        let plan = (try? JSONDecoder().decode(Initialize.self, from: initData))?.account?.subscriptionType.flatMap(planName)
        var snapshot = ClaudeUsageAPI.snapshot(from: limits, plan: plan)
        snapshot.source = .cliProcess
        return snapshot
    }

    /// The CLI names the plan in full ("Claude Max"); the card already says Claude.
    static func planName(_ subscription: String) -> String? {
        var name = subscription.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasPrefix("claude ") { name = String(name.dropFirst("claude ".count)) }
        guard !name.isEmpty else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The flags the Agent SDK uses for a capabilities probe, minus everything a usage read doesn't
    /// need: no settings files, hooks, MCP servers, IDE connection or saved session.
    static let arguments = [
        "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
        "--no-session-persistence", "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#,
        "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
    ]

    /// The `response`s of the `initialize` and `get_usage` control requests, as JSON.
    private static func readUsage(executable: String, folder: URL?, timeout: TimeInterval) throws -> (Data, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        // GUI apps get a minimal PATH; an npm-installed CLI is a node script.
        env["PATH"] = (Paths.cliDirectories() + ["/usr/bin", "/bin", env["PATH"] ?? ""]).joined(separator: ":")
        if let folder { env["CLAUDE_CONFIG_DIR"] = folder.path }
        env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        env["CLAUDE_CODE_AUTO_CONNECT_IDE"] = "0"
        env["CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL"] = "1"
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ProviderError.unexpected("Could not prepare claude input")
        }

        do { try process.run() } catch { throw ProviderError.unexpected("Could not launch claude: \(error.localizedDescription)") }
        let pid = process.processIdentifier
        let target = getpgid(pid) == pid ? -pid : pid
        defer {
            try? stdin.fileHandleForWriting.close()
            kill(target, SIGKILL)
            process.waitUntilExit()
        }
        let watchdog = DispatchWorkItem { kill(target, SIGKILL) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        func send(_ id: String, _ request: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": request])
            data.append(0x0A)
            do { try stdin.fileHandleForWriting.write(contentsOf: data) }
            catch { throw ProviderError.unexpected("claude closed its input") }
        }

        var reader = LineReader(handle: stdout.fileHandleForReading)
        func response(_ id: String) throws -> [String: Any] {
            while let line = try reader.next() {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] as? String == "control_response",
                      let response = obj["response"] as? [String: Any],
                      response["request_id"] as? String == id
                else { continue }
                // Its error text can carry upstream response bodies.
                guard response["subtype"] as? String == "success" else { throw ProviderError.loginExpired }
                return response["response"] as? [String: Any] ?? [:]
            }
            throw ProviderError.unexpected("claude exited without answering")
        }

        try send("init", ["subtype": "initialize"])
        let initialized = try JSONSerialization.data(withJSONObject: response("init"))
        // skip_behaviors: only the limits are wanted, not a scan of every local transcript.
        try send("usage", ["subtype": "get_usage", "skip_behaviors": true])
        return (initialized, try JSONSerialization.data(withJSONObject: response("usage")))
    }
}
