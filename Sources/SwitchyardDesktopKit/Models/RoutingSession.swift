import Foundation

/// One client conversation, grouped from the `session_id` Switchyard stamps on
/// every record it appends.
///
/// The log carries no session start or end event, so a session is only ever
/// what its records say: the first and last call that quoted the same id, the
/// models they reached, and what they cost. A session the client is still using
/// simply keeps growing on the next refresh.
package struct RoutingSession: Identifiable, Equatable, Sendable {
    package let id: String
    /// Absent when none of the session's records carried a timestamp.
    package let startedAt: Date?
    package let lastActivity: Date?
    /// Turns served to the client. Judge calls are counted apart, exactly as
    /// `RoutingMetrics` counts them.
    package let turns: Int
    package let classifierCalls: Int
    package let tokens: Int
    /// Models that served a turn, most recently used first.
    package let models: [String]
    package let origin: String?
    /// The name Codex shows for this conversation, when its own index still
    /// carries one. Sessions from another client, or ones Codex has pruned,
    /// have none and are named by their id instead.
    package let name: String?

    /// The window the session actually covers, for metrics that should be read
    /// per session rather than per wall-clock window.
    package var span: DateInterval? {
        guard let startedAt, let lastActivity, lastActivity >= startedAt else { return nil }
        return DateInterval(start: startedAt, end: lastActivity)
    }

    /// The tail of the id: the head of a UUIDv7 is a timestamp, so neighbouring
    /// sessions differ only at the end.
    package var shortID: String { String(id.suffix(6)) }

    /// What to call the session: its Codex name, or the id it is known by when
    /// there is no name to show.
    package var title: String { name ?? "Session \(shortID)" }

    /// A single-line form for a chart corner or a footnote, where a long thread
    /// name would push everything else off the row.
    package var shortTitle: String {
        title.count <= 34 ? title : title.prefix(33).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// How the session reads inside a sentence: an unnamed one has to say what
    /// the bare id is, a named one speaks for itself.
    package var scopeName: String { name == nil ? "session \(shortID)" : shortTitle }

    /// When it ran and how much it routed, for the line under the name.
    package var detail: String {
        let time = startedAt?.formatted(date: .omitted, time: .shortened)
        let turnText = "\(turns) turn\(turns == 1 ? "" : "s")"
        let modelText = models.isEmpty ? "no model recorded" : models.joined(separator: ", ")
        return [time, turnText, modelText].compactMap { $0 }.joined(separator: " · ")
    }

    /// Newest activity first, so the conversation in front of the user is the
    /// first thing the picker offers.
    package static func sessions(
        from records: [RoutingLogRecord], names: [String: String] = [:]
    ) -> [RoutingSession] {
        var order: [String] = []
        var totals: [String: Totals] = [:]
        for record in records {
            guard let id = record.sessionID, !id.isEmpty else { continue }
            if totals[id] == nil {
                totals[id] = Totals()
                order.append(id)
            }
            totals[id]?.add(record)
        }
        return order.compactMap { id in totals[id]?.session(id: id, name: names[id]) }
            .sorted {
                switch ($0.lastActivity, $1.lastActivity) {
                case let (lhs?, rhs?): return lhs > rhs
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return $0.id < $1.id
                }
            }
    }

    private struct Totals {
        package var startedAt: Date?
        package var lastActivity: Date?
        package var turns = 0
        package var classifierCalls = 0
        package var tokens = 0
        package var origin: String?
        /// Records arrive newest first, so first sighting is most recent use.
        package var models: [String] = []
        private var seenModels: Set<String> = []

        package mutating func add(_ record: RoutingLogRecord) {
            if let timestamp = record.timestamp {
                if startedAt.map({ timestamp < $0 }) ?? true { startedAt = timestamp }
                if lastActivity.map({ timestamp > $0 }) ?? true { lastActivity = timestamp }
            }
            tokens += record.tokens.total
            if record.isClassifier {
                classifierCalls += 1
            } else {
                turns += 1
                let model = record.modelIdentity
                if seenModels.insert(model).inserted { models.append(model) }
            }
            if origin == nil { origin = record.origin }
        }

        package func session(id: String, name: String?) -> RoutingSession {
            RoutingSession(
                id: id, startedAt: startedAt, lastActivity: lastActivity, turns: turns,
                classifierCalls: classifierCalls, tokens: tokens, models: models,
                origin: origin, name: name
            )
        }
    }
}
