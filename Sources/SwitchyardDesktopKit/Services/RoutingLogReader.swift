import Foundation

/// One routed turn, read back from the durable JSONL log that
/// `switchyard-server --routing-log-file` appends to.
///
/// Switchyard owns that record's schema, so this type keeps the flattened raw
/// fields alongside the few values the UI reads by name. Anything it cannot
/// recognise still reaches the request detail pane verbatim instead of being
/// dropped or guessed at.
///
/// The record is a *usage* record, not a request trace: Switchyard appends it
/// once a call's token usage is known. It carries no latency, HTTP status, or
/// per-request identifier — those live only in the proxy's own `/v1/stats`
/// counters, which `SwitchyardStatsClient` reads.
package struct RoutingLogRecord: Identifiable, Equatable, Sendable {
    package struct Field: Equatable, Sendable, Identifiable {
        package let name: String
        package let value: String
        package var id: String { name }
    }

    package struct Tokens: Equatable, Sendable {
        package var prompt = 0
        package var cached = 0
        package var cacheCreation = 0
        package var completion = 0
        package var reasoning = 0
        package var total = 0
    }

    /// Switchyard's own value for a judge call's `tier`.
    package static let classifierTier = "classifier"

    package let id: Int
    package let timestamp: Date?
    package let model: String?
    /// Switchyard's `tier`: `classifier` for a judge call, the selected tier for
    /// algorithms that record one, and empty for a plain served turn.
    package let tier: String?
    /// The task the classifier chose, when the algorithm reports one.
    package let task: String?
    /// The client label the caller sent in `x-switchyard-origin`. Absent for a
    /// client that sends no label, and for records written before Switchyard
    /// recorded one.
    package let origin: String?
    package let sessionID: String?
    /// Which agent made the call, when the harness identifies its agents: the
    /// child's own id for delegated work, the parent thread's otherwise.
    ///
    /// Both Codex and Claude Code report a child under the *parent's*
    /// `session_id`, so a session cannot separate them and this can.
    package var agentID: String? = nil
    package var parentAgentID: String? = nil
    /// Switchyard's `delegated`: the call was routed over the sub-agent's own
    /// models rather than the parent's.
    package var isDelegated = false
    /// The harness's own label for the child, and the role it was spawned as,
    /// when either is reported.
    package var agentKind: String? = nil
    package var agentRole: String? = nil
    /// The harness cannot identify its children, so its delegated calls look
    /// like the parent's. A reader has to say that rather than report that
    /// nothing was delegated.
    package var subagentIdentityUnsupported = false
    package let route: String?
    package let algorithm: String?
    package let tokens: Tokens
    package let fields: [Field]
    /// Missing usage must not look like an empty context window. Unlike the
    /// aggregate token counters, this preserves absence and a reported zero.
    package var contextInputTokens: Int? = nil

    package var modelIdentity: String { model ?? "unknown" }

    /// A judge call pays for routing; it is not a turn served to the user.
    package var isClassifier: Bool {
        tier?.caseInsensitiveCompare(Self.classifierTier) == .orderedSame
    }
}

package final class RoutingLogReader: @unchecked Sendable {
    /// Written inside the directory this app owns, never in the Codex or
    /// Switchyard directories.
    package static var defaultLogURL: URL {
        SwitchyardConfigWriter.supportDirectory
            .appendingPathComponent("routing-log.jsonl")
    }

    /// Cap on how much of the tail is parsed, so a long-lived log cannot stall
    /// the statistics window.
    package static let tailByteLimit = 1_024 * 1_024

    package let url: URL
    /// Only the latest bounded tail is retained. The lock covers both the read
    /// and cache update so overlapping background refreshes share one snapshot.
    private let lock = NSLock()
    private var cachedData: Data?
    private var cachedLimit = 0
    private var cachedRecords: [RoutingLogRecord] = []

    package init(url: URL = RoutingLogReader.defaultLogURL) {
        self.url = url
    }

    package var logExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Newest record first. An unreadable or absent log reads as empty.
    package func recentRecords(limit: Int = 500) -> [RoutingLogRecord] {
        guard limit > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let data = tailData() else {
            cachedData = nil
            cachedRecords = []
            return []
        }
        // Compare bytes rather than file size/mtime: same-sized rewrites and
        // a completed partial line must be visible on the next refresh.
        if data == cachedData, limit == cachedLimit { return cachedRecords }
        var records: [RoutingLogRecord] = []
        var end = data.endIndex
        // Walk backwards only as far as needed; do not decode the entire tail
        // into a String or allocate a collection containing every line.
        while end > data.startIndex && records.count < limit {
            let separator = data[..<end].lastIndex(of: UInt8(ascii: "\n"))
            let start = separator.map { $0 + 1 } ?? data.startIndex
            let line = data[start..<end]
            end = separator ?? data.startIndex
            guard !line.isEmpty,
                  let record = Self.record(from: line, id: records.count) else { continue }
            records.append(record)
        }
        cachedData = data
        cachedLimit = limit
        cachedRecords = records
        return records
    }

    private func tailData() -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(Self.tailByteLimit) ? size - UInt64(Self.tailByteLimit) : 0
        do {
            try handle.seek(toOffset: offset)
            // A writer can keep appending while we read. Read only the size
            // observed above, so the byte limit remains a hard allocation cap.
            let data = try handle.read(upToCount: Int(size - offset)) ?? Data()
            if offset > 0 {
                guard let firstBreak = data.firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
                return data[(firstBreak + 1)...]
            }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Record decoding

    package static func record(from line: String, id: Int) -> RoutingLogRecord? {
        record(from: Data(line.utf8), id: id)
    }

    private static func record(from data: Data, id: Int) -> RoutingLogRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        var flattened: [String: Any] = [:]
        flatten(dictionary, prefix: "", into: &flattened)
        let lookup = FieldLookup(flattened)

        let fields = flattened
            .map { RoutingLogRecord.Field(name: $0.key, value: string(from: $0.value)) }
            .sorted { $0.name < $1.name }

        return RoutingLogRecord(
            id: id,
            timestamp: date(in: lookup),
            model: firstString(in: lookup, keys: ["model", "selected_model", "model_id"]),
            tier: firstString(in: lookup, keys: ["tier", "selected_target", "target"]),
            task: firstString(in: lookup, keys: ["task", "decision", "label"]),
            origin: firstString(in: lookup, keys: ["origin", "client"]),
            sessionID: firstString(in: lookup, keys: ["session_id", "session", "conversation_id"]),
            agentID: firstString(in: lookup, keys: ["agent_id", "subagent_id", "thread_id"]),
            parentAgentID: firstString(in: lookup, keys: ["parent_agent_id", "parent_thread_id"]),
            isDelegated: boolean(in: lookup, keys: ["delegated", "is_delegated_work", "is_subagent"]),
            agentKind: firstString(in: lookup, keys: ["agent_kind", "subagent_kind"]),
            agentRole: firstString(in: lookup, keys: ["agent_role"]),
            subagentIdentityUnsupported: boolean(in: lookup, keys: ["subagent_identity_unsupported"]),
            route: firstString(in: lookup, keys: ["route_id", "route", "router"]),
            algorithm: firstString(in: lookup, keys: ["algorithm", "router_algorithm"]),
            tokens: tokens(in: lookup),
            fields: fields,
            contextInputTokens: contextInputTokens(in: lookup)
        )
    }

    private static func contextInputTokens(in fields: FieldLookup) -> Int? {
        for key in ["prompt_tokens", "input_tokens"] {
            let value = fields.value(for: key)
            if let number = value as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(),
               let count = Int(number.stringValue), count >= 0 { return count }
            if let text = value as? String, let count = Int(text), count >= 0 { return count }
        }
        return nil
    }

    private static func tokens(in fields: FieldLookup) -> RoutingLogRecord.Tokens {
        var tokens = RoutingLogRecord.Tokens()
        tokens.prompt = integer(in: fields, keys: ["prompt_tokens", "input_tokens"])
        tokens.cached = integer(in: fields, keys: ["cached_tokens", "cache_read_tokens"])
        tokens.cacheCreation = integer(in: fields, keys: ["cache_creation_tokens"])
        tokens.completion = integer(in: fields, keys: ["completion_tokens", "output_tokens"])
        tokens.reasoning = integer(in: fields, keys: ["reasoning_tokens"])
        // A record from a schema without the sum still reports one.
        let total = integer(in: fields, keys: ["total_tokens"])
        tokens.total = total > 0 ? total : tokens.prompt + tokens.completion
        return tokens
    }

    private static func flatten(_ dictionary: [String: Any], prefix: String, into output: inout [String: Any]) {
        for (key, value) in dictionary {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                flatten(nested, prefix: path, into: &output)
            } else {
                output[path] = value
            }
        }
    }

    /// Matches a candidate key against the record's own naming: exact path,
    /// last path component, and a case- and separator-insensitive comparison.
    private struct FieldLookup {
        package let exact: [String: Any]
        private var aliases: [String: Any] = [:]

        package init(_ fields: [String: Any]) {
            exact = fields
            // Normalize once per field, instead of rescanning and normalizing
            // every field for each missing/alternative schema key.
            for (path, value) in fields {
                let full = normalized(path)
                if aliases[full] == nil { aliases[full] = value }
                if let dot = path.lastIndex(of: ".") {
                    let leaf = normalized(String(path[path.index(after: dot)...]))
                    if aliases[leaf] == nil { aliases[leaf] = value }
                }
            }
        }

        package func value(for key: String) -> Any? { exact[key] ?? aliases[normalized(key)] }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func firstString(in fields: FieldLookup, keys: [String]) -> String? {
        for key in keys {
            // A JSON `null` is an absent value, not the placeholder `string(from:)`
            // renders it as for the raw field list.
            guard let value = fields.value(for: key), !(value is NSNull) else { continue }
            let text = string(from: value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != "null" { return text }
        }
        return nil
    }

    /// A flag can arrive as a JSON boolean, or as the string or number a writer
    /// that flattens one leaves behind. Absence reads as false, exactly as the
    /// omitted field Switchyard writes for a call with no agent identity.
    private static func boolean(in fields: FieldLookup, keys: [String]) -> Bool {
        for key in keys {
            guard let value = fields.value(for: key), !(value is NSNull) else { continue }
            if let number = value as? NSNumber { return number.boolValue }
            let text = string(from: value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1"].contains(text) { return true }
            if ["false", "no", "0"].contains(text) { return false }
        }
        return false
    }

    private static func integer(in fields: FieldLookup, keys: [String]) -> Int {
        for key in keys {
            guard let value = fields.value(for: key) else { continue }
            if let number = value as? NSNumber { return number.intValue }
            if let text = value as? String, let number = Int(text) { return number }
        }
        return 0
    }

    private static func date(in fields: FieldLookup) -> Date? {
        let keys = ["ts", "timestamp", "time", "at", "started_at", "recorded_at", "received_at"]
        for key in keys {
            guard let value = fields.value(for: key) else { continue }
            if let text = value as? String, let date = parseDate(text) { return date }
            if let number = value as? NSNumber {
                let seconds = number.doubleValue
                // Millisecond epochs are the common alternative to seconds.
                return Date(timeIntervalSince1970: seconds > 1_000_000_000_000 ? seconds / 1000 : seconds)
            }
        }
        return nil
    }

    private static func parseDate(_ text: String) -> Date? {
        // FormatStyle is a Sendable value; Foundation caches its parsing setup.
        (try? fractionalDateStyle.parse(text)) ?? (try? dateStyle.parse(text))
    }

    private static let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let dateStyle = Date.ISO8601FormatStyle()

    private static func string(from value: Any) -> String {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            if number === kCFBooleanTrue { return "true" }
            if number === kCFBooleanFalse { return "false" }
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 1e15
                ? String(Int64(double))
                : String(format: "%.4g", double)
        case is NSNull:
            return "—"
        case let list as [Any]:
            return list.map { string(from: $0) }.joined(separator: ", ")
        default:
            return String(describing: value)
        }
    }
}
