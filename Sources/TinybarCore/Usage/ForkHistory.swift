import Foundation
import SQLite3

/// One response's usage from a history the upstream app doesn't read: the Grok CLI's session
/// updates and Antigravity's conversation databases, read as T3 Code reads them (ADR 0017).
struct HistoryRecord: Sendable {
    /// Every id the response is known by. Any one shared means the same response: Antigravity
    /// files a call under its step and its generation, and either can come first.
    var keys: [String]
    var timestamp: Date
    /// 2 for the response's own time, 1 for its conversation's, 0 for the file's.
    var timestampQuality: Int
    var model: String
    var cwd: String?
    var tokens: TokenCounts
    /// What the CLI priced it at, in USD, when it says.
    var cost: Double?
}

/// More than any response could use. Keeps a corrupt count from overflowing the sums.
private let maxTokens: Int64 = 1 << 40

// MARK: Grok

/// The Grok CLI writes each turn's usage to `sessions/<cwd>/<session>/updates.jsonl` as a
/// `turn_completed` update, per model and with what it cost (`costUsdTicks`).
enum GrokHistory {
    static func sessionsRoot(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        Paths.grokHome(env: env).appendingPathComponent("sessions", isDirectory: true)
    }

    static let fileName = "updates.jsonl"
    static let ticksPerDollar = 10_000_000_000.0

    /// The session folder's parent is the working directory, percent-encoded.
    static func cwd(ofFile path: String, root: String) -> String? {
        let relative = path.dropFirst(root.count).split(separator: "/")
        guard relative.count == 3 else { return nil }
        return String(relative[0]).removingPercentEncoding
    }

    private struct Totals {
        var input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64
        var cost: Double?

        init?(_ value: Any?) {
            guard let d = value as? [String: Any] else { return nil }
            func count(_ key: String) -> Int64 {
                guard let n = d[key] as? NSNumber, n.doubleValue.isFinite, n.doubleValue >= 0 else { return 0 }
                return min(Int64(n.doubleValue), maxTokens)
            }
            input = count("inputTokens")
            output = count("outputTokens")
            cacheRead = count("cachedReadTokens")
            cacheWrite = count("cacheCreationTokens")
            cost = (d["costUsdTicks"] as? NSNumber).flatMap { $0.doubleValue.isFinite && $0.doubleValue >= 0 ? $0.doubleValue / GrokHistory.ticksPerDollar : nil }
        }

        /// `inputTokens` includes the cached part, as Codex's does; `outputTokens` includes reasoning.
        var tokens: TokenCounts {
            TokenCounts(input: max(0, input - cacheRead - cacheWrite), output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
        }
    }

    /// The records of one `updates.jsonl` line; none unless it is a finished turn with usage.
    static func records(line: Data, cwd: String?) -> [HistoryRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let params = root["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any],
              let total = Totals(usage)
        else { return [] }
        let session = params["sessionId"] as? String ?? ""
        let promptID = update["prompt_id"] as? String
        let millis = ((params["_meta"] as? [String: Any])?["agentTimestampMs"] as? NSNumber)?.doubleValue
            ?? (root["timestamp"] as? NSNumber).map { $0.doubleValue > 1e12 ? $0.doubleValue : $0.doubleValue * 1000 }
        guard let millis, millis.isFinite, millis > 0 else { return [] }
        let at = Date(timeIntervalSince1970: millis / 1000)

        var perModel: [(String, Totals)] = []
        for (model, raw) in (usage["modelUsage"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) where !model.isEmpty {
            if let t = Totals(raw), !t.tokens.isZero { perModel.append((model, t)) }
        }
        if perModel.isEmpty {
            guard !total.tokens.isZero else { return [] }
            perModel = [("grok", total)]
        }
        // A model without its own cost gets its token share of what the turn's cost leaves.
        let priced = perModel.compactMap(\.1.cost).reduce(0, +)
        let unpricedTokens = perModel.filter { $0.1.cost == nil }.map { Double($0.1.tokens.total) }.reduce(0, +)
        let left = total.cost.map { max(0, $0 - priced) }
        return perModel.map { model, t in
            let cost = t.cost ?? left.flatMap { unpricedTokens > 0 ? $0 * Double(t.tokens.total) / unpricedTokens : nil }
            // Without a prompt id two turns can't be told apart, so the line itself is the key.
            let key = promptID.map { "grok:\(session):\($0):\(model)" } ?? "grok:\(session):\(Int64(millis)):\(model)"
            return HistoryRecord(keys: [key], timestamp: at, timestampQuality: 2, model: model, cwd: cwd, tokens: t.tokens, cost: cost)
        }
    }
}

// MARK: Antigravity

/// Antigravity keeps each conversation in a SQLite database whose `steps` and `gen_metadata` rows
/// hold protobuf blobs with each model call's usage. Read as T3 Code reads them; field numbers
/// are Antigravity's, not documented.
enum AntigravityHistory {
    /// The CLI's and the IDE's data folders, or `ANTIGRAVITY_DATA_DIR`, and the profiles T3 Code
    /// runs Antigravity with. Each is searched for `.db` files under its `conversations` folder.
    static func conversationRoots(env: [String: String] = ProcessInfo.processInfo.environment, home: URL = Paths.home) -> [URL] {
        let configured = (env["ANTIGRAVITY_DATA_DIR"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        var roots = configured.isEmpty
            ? ["antigravity", "antigravity-cli", "antigravity-ide", "antigravity-backup"].map { home.appendingPathComponent(".gemini/\($0)", isDirectory: true) }
                + [home.appendingPathComponent(".config/antigravity", isDirectory: true)]
            : configured
        let t3 = home.appendingPathComponent(".t3/userdata/providers/antigravity", isDirectory: true)
        for profile in (try? FileManager.default.contentsOfDirectory(atPath: t3.path)) ?? [] {
            roots.append(t3.appendingPathComponent("\(profile)/antigravity-acp", isDirectory: true))
        }
        var seen = Set<String>()
        return roots.compactMap { root in
            let nested = root.appendingPathComponent("conversations", isDirectory: true)
            let dir = FileManager.default.fileExists(atPath: nested.path) ? nested : root
            let real = dir.resolvingSymlinksInPath()
            return FileManager.default.fileExists(atPath: real.path) && seen.insert(real.path).inserted ? real : nil
        }
    }

    /// Every conversation database under the roots. Symbolic links are left alone.
    static func databases(in roots: [URL]) -> [String] {
        var out: [String] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in walker where url.pathExtension == "db" {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true, values?.isSymbolicLink != true { out.append(url.path) }
            }
        }
        return out.sorted()
    }

    /// The usage in one conversation database, or nil if it couldn't be read as expected.
    static func read(database path: String) -> [HistoryRecord]? {
        var handle: OpaquePointer?
        // Read in place: copying a database of many megabytes on every change would cost more than
        // the read. A writer holding it busy gets a short wait, then the next ingest tries again.
        // Without a WAL beside it, a WAL-mode database only opens read-only as immutable.
        let hasWAL = FileManager.default.fileExists(atPath: path + "-wal")
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?" + (hasWAL ? "mode=ro" : "immutable=1")
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            return nil
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 200)
        guard sqlite3_exec(handle, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_exec(handle, "COMMIT", nil, nil, nil) }
        let hasSteps = SQLiteDB.hasTable("steps", in: handle), hasGenerations = SQLiteDB.hasTable("gen_metadata", in: handle)
        guard hasSteps || hasGenerations else { return nil }

        var trajectory: Date?
        var workspace: String?
        if SQLiteDB.hasTable("trajectory_metadata_blob", in: handle) {
            guard each(handle, "SELECT data FROM trajectory_metadata_blob", { blob in
                guard let message = Protobuf(blob) else { return }
                trajectory = trajectory ?? message.message(2)?.timestamp
                // The conversation's workspace, as a `file://` URL.
                workspace = workspace ?? message.text(7).flatMap { URL(string: $0) }.flatMap { $0.isFileURL ? $0.path : nil }
            }) else { return nil }
        }
        var steps: [(Int64, Metadata)] = [], generations: [(Int64, Metadata)] = []
        if hasSteps {
            guard eachIndexed(handle, "SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL", { idx, blob in
                if let m = Metadata(blob, step: true) { steps.append((idx, m)) }
            }) else { return nil }
        }
        if hasGenerations {
            guard eachIndexed(handle, "SELECT idx, data FROM gen_metadata", { idx, blob in
                if let m = Metadata(blob, step: false) { generations.append((idx, m)) }
            }) else { return nil }
        }
        let session = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let fileTime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        return records(session: session, steps: steps.sorted { $0.0 < $1.0 }, generations: generations.sorted { $0.0 < $1.0 },
                       trajectory: trajectory, workspace: workspace, fileTime: fileTime)
    }

    static func records(
        session: String, steps: [(Int64, Metadata)], generations: [(Int64, Metadata)], trajectory: Date?, workspace: String?,
        fileTime: Date) -> [HistoryRecord]
    {
        let generationModels = Dictionary(generations.map { ($0.0, $0.1.model) }, uniquingKeysWith: { first, _ in first })
        // Step rows give only the model's number; generation rows name it, and newer models
        // aren't in `modelIDs`.
        var named = modelIDs
        for (_, entry) in steps + generations where !entry.model.isEmpty && entry.modelID > 0 {
            named[entry.modelID] = named[entry.modelID] ?? entry.model
        }
        var out: [HistoryRecord] = []
        for (source, entries) in [("step", steps), ("generation", generations)] {
            for (index, (idx, entry)) in entries.enumerated() {
                for (usageIndex, usage) in entry.usages.enumerated() {
                    let output = max(usage.int(3), usage.int(9) + usage.int(10))
                    let tokens = TokenCounts(input: usage.int(2), output: output, cacheWrite: usage.int(4), cacheRead: usage.int(5))
                    guard !tokens.isZero, [tokens.input, tokens.output, tokens.cacheWrite, tokens.cacheRead].allSatisfy({ $0 <= maxTokens })
                    else { continue }
                    let ids = [11, 12, 7].compactMap { key in usage.text(key).map { "antigravity:\(key):\($0)" } }
                    let model = named[usage.int(1)]
                        ?? (entry.model.isEmpty ? nil : entry.model)
                        ?? (source == "step" ? generationModels[idx].flatMap { $0.isEmpty ? nil : $0 } : nil)
                        ?? named[entry.modelID]
                        ?? modelName("", id: usage.int(1))
                    out.append(HistoryRecord(
                        keys: ids.isEmpty ? ["antigravity:\(session):\(source):\(index):\(usageIndex)"] : ids,
                        timestamp: entry.timestamp ?? trajectory ?? fileTime,
                        timestampQuality: entry.timestamp != nil ? 2 : trajectory != nil ? 1 : 0,
                        model: model.isEmpty ? "antigravity-unknown" : model,
                        cwd: workspace, tokens: tokens, cost: nil))
                }
            }
        }
        return out
    }

    struct Metadata {
        /// Empty when the row names no model.
        var model: String
        var modelID: Int64
        var timestamp: Date?
        var usages: [Protobuf]

        init?(_ blob: UnsafeRawBufferPointer, step: Bool) {
            guard let root = Protobuf(blob) else { return nil }
            guard let data = step ? root : root.message(1) else { return nil }
            let modelInfo = step ? data.message(24) : data
            let id = modelInfo?.int(step ? 1 : 3) ?? 0
            modelID = id
            let name = modelInfo?.text(step ? 12 : 19) ?? modelInfo?.text(step ? 8 : 21)
            model = name.map { AntigravityHistory.modelName($0, id: id) } ?? ""
            timestamp = step ? (data.message(8)?.timestamp ?? data.message(1)?.timestamp) : data.message(9)?.message(4)?.timestamp
            usages = []
            if let usage = data.message(step ? 9 : 4) { usages.append(usage) }
            for retry in data.messages(step ? 28 : 17) {
                if let usage = retry.message(2) { usages.append(usage) }
            }
        }
    }

    /// Antigravity's model enum, for calls that name no model.
    static let modelIDs: [Int64: String] = [
        246: "gemini-2.5-pro", 312: "gemini-2.5-flash", 313: "gemini-2.5-flash-thinking", 329: "gemini-2.5-flash-thinking",
        330: "gemini-2.5-flash-lite", 281: "claude-sonnet-4", 282: "claude-sonnet-4", 290: "claude-opus-4", 291: "claude-opus-4",
        333: "claude-sonnet-4-5", 334: "claude-sonnet-4-5", 340: "claude-haiku-4-5", 341: "claude-haiku-4-5",
        1026: "claude-opus-4-6", 1035: "claude-sonnet-4-6", 1016: "gemini-3.1-pro", 1036: "gemini-3.1-pro", 1037: "gemini-3.1-pro",
        1018: "gemini-3-flash-preview", 1084: "gemini-3-flash-preview", 1047: "gemini-3-flash-preview",
    ]

    /// "Claude Sonnet 4.6 (Thinking)" → "claude-sonnet-4-6", as model ids are spelled elsewhere. A
    /// thinking level ("gemini-4-argon-high") is the same model at the same price.
    static func modelName(_ name: String, id: Int64) -> String {
        guard !name.isEmpty else { return modelIDs[id] ?? (id > 0 ? "antigravity-model-\(id)" : "") }
        var s = name.lowercased().replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: #"-(low|medium|high|xhigh)$"#, with: "", options: .regularExpression)
        if s.hasPrefix("claude-") {
            s = s.replacingOccurrences(of: #"^claude-(4(?:\.\d+)?)-(sonnet|opus|haiku)"#, with: "claude-$2-$1", options: .regularExpression)
                .replacingOccurrences(of: ".", with: "-")
        }
        return s
    }

    private static func each(_ handle: OpaquePointer, _ sql: String, _ body: (UnsafeRawBufferPointer) -> Void) -> Bool {
        eachIndexed(handle, sql.replacingOccurrences(of: "SELECT data", with: "SELECT 0, data")) { body($1) }
    }

    /// Steps one row at a time: a generation row can hold megabytes of context.
    private static func eachIndexed(_ handle: OpaquePointer, _ sql: String, _ body: (Int64, UnsafeRawBufferPointer) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return true }
            guard rc == SQLITE_ROW else { return false }
            guard sqlite3_column_type(stmt, 1) == SQLITE_BLOB, let bytes = sqlite3_column_blob(stmt, 1) else { continue }
            autoreleasepool { body(sqlite3_column_int64(stmt, 0), UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(stmt, 1)))) }
        }
    }
}

/// The fields of one protobuf message, enough to read Antigravity's metadata. Nested messages are
/// copied out, so nothing points into the SQLite row after it.
struct Protobuf {
    private enum Field {
        case varint(UInt64)
        case bytes([UInt8])
    }

    private var fields: [Int: [Field]] = [:]

    init?(_ buffer: UnsafeRawBufferPointer) {
        self.init(bytes: Array(buffer))
    }

    init?(bytes: [UInt8]) {
        var offset = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while offset < bytes.count, shift < 64 {
                let byte = bytes[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            return nil
        }
        while offset < bytes.count {
            guard let tag = varint(), tag >> 3 > 0, tag >> 3 < 1 << 29 else { return nil }
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let v = varint() else { return nil }
                fields[number, default: []].append(.varint(v))
            case 1, 5:
                let length = tag & 7 == 1 ? 8 : 4
                guard length <= bytes.count - offset else { return nil }
                offset += length
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - offset) else { return nil }
                fields[number, default: []].append(.bytes(Array(bytes[offset..<offset + Int(length)])))
                offset += Int(length)
            default:
                return nil
            }
        }
    }

    func int(_ number: Int) -> Int64 {
        guard case let .varint(v)? = fields[number]?.first, v <= UInt64(Int64.max) else { return 0 }
        return Int64(v)
    }

    func text(_ number: Int) -> String? {
        guard case let .bytes(b)? = fields[number]?.first, let s = String(bytes: b, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
              !s.isEmpty else { return nil }
        return s
    }

    func message(_ number: Int) -> Protobuf? {
        guard case let .bytes(b)? = fields[number]?.first else { return nil }
        return Protobuf(bytes: b)
    }

    func messages(_ number: Int) -> [Protobuf] {
        (fields[number] ?? []).compactMap { if case let .bytes(b) = $0 { Protobuf(bytes: b) } else { nil } }
    }

    /// A `google.protobuf.Timestamp`.
    var timestamp: Date? {
        let seconds = int(1)
        return seconds > 0 ? Date(timeIntervalSince1970: Double(seconds) + Double(int(2) / 1_000_000) / 1000) : nil
    }
}
