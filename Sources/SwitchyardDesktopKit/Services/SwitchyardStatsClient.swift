import Foundation

/// Routing counters the running proxy reports on `GET /v1/stats`.
///
/// Switchyard owns the payload, so every field is decoded defensively: a value
/// the server stops reporting reads as zero rather than failing the whole
/// snapshot.
package struct RoutingStats: Equatable, Sendable {
    package struct Tokens: Equatable, Sendable {
        package var prompt = 0
        package var completion = 0
        package var cached = 0
        package var reasoning = 0
        package var total = 0
    }

    package struct ModelUsage: Equatable, Sendable, Identifiable {
        package let id: String
        package let requests: Int
        package let errors: Int
        package let tokens: Int
        package var latency: Latency?
    }

    package struct Latency: Equatable, Sendable {
        package let count: Int
        package let p50Milliseconds: Double
        package let p99Milliseconds: Double
    }

    package struct Overhead: Equatable, Sendable {
        package var count = 0
        package var averageMilliseconds = 0.0
        package var p50Milliseconds = 0.0
        package var p99Milliseconds = 0.0
        package var maximumMilliseconds = 0.0
    }

    package var totalRequests = 0
    package var totalErrors = 0
    package var tokens = Tokens()
    package var models: [ModelUsage] = []
    package var overhead = Overhead()
    package var fallbacks: [String: Int] = [:]
    package var classifierRequests = 0
    package var classifierErrors = 0
    /// `algorithm_stats.<algorithm>.routing_decisions`: target name to count.
    package var routingDecisions: [String: Int] = [:]
    package var algorithm: String?

    package var totalFallbacks: Int { fallbacks.values.reduce(0, +) }
}

/// Reads the managed proxy's own statistics endpoint over loopback.
package struct SwitchyardStatsClient: Sendable {
    package enum Failure: LocalizedError, Equatable {
        case unreachable
        case unexpectedResponse

        package var errorDescription: String? {
            switch self {
            case .unreachable:
                "The local proxy is not answering on its statistics endpoint."
            case .unexpectedResponse:
                "The local proxy returned statistics switchyard-desktop could not read."
            }
        }
    }

    private let session: URLSession

    package init(timeout: TimeInterval = 2) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// `host` and `port` are the app's own loopback proxy — never the default
    /// Switchyard port, which another instance on this machine owns.
    package func stats(host: String, port: Int) async throws -> RoutingStats {
        let urlHost = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(urlHost):\(port)/v1/stats") else {
            throw Failure.unreachable
        }

        let data: Data
        do {
            (data, _) = try await session.data(from: url)
        } catch {
            throw Failure.unreachable
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            throw Failure.unexpectedResponse
        }
        return Self.decode(payload)
    }

    // MARK: - Decoding

    /// Read the capabilities of the route actually loaded by the managed
    /// server, so pending edits to routes.toml cannot masquerade as live limits.
    package func routeContextWindows(host: String, port: Int) async throws -> [String: Int] {
        let urlHost = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(urlHost):\(port)/v1/models") else {
            throw Failure.unreachable
        }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unexpectedResponse
        }
        return SwitchyardRouteContext.advertisedWindows(in: payload)
    }

    package static func decode(_ payload: [String: Any]) -> RoutingStats {
        var stats = RoutingStats()
        stats.totalRequests = integer(payload["total_requests"])
        stats.totalErrors = integer(payload["total_errors"])
        stats.tokens = tokens(payload["total_tokens"])
        stats.models = models(payload["models"])
        stats.overhead = overhead(payload["routing_overhead"])

        if let fallbacks = payload["routing_fallbacks"] as? [String: Any] {
            stats.fallbacks = fallbacks.compactMapValues { value in
                let count = integer(value)
                return count > 0 ? count : nil
            }
        }

        if let classifier = payload["classifier"] as? [String: Any] {
            stats.classifierRequests = integer(classifier["total_requests"])
            stats.classifierErrors = integer(classifier["total_errors"])
        }

        // One algorithm is configured per generated route, so the first entry
        // carrying decisions is the active one.
        if let algorithms = payload["algorithm_stats"] as? [String: Any] {
            for (name, value) in algorithms.sorted(by: { $0.key < $1.key }) {
                guard let entry = value as? [String: Any] else { continue }
                let decisions = (entry["routing_decisions"] as? [String: Any]) ?? [:]
                let counted = decisions.compactMapValues { value -> Int? in
                    let count = integer(value)
                    return count > 0 ? count : nil
                }
                if stats.algorithm == nil { stats.algorithm = name }
                if !counted.isEmpty {
                    stats.algorithm = name
                    stats.routingDecisions = counted
                    break
                }
            }
        }
        return stats
    }

    private static func tokens(_ value: Any?) -> RoutingStats.Tokens {
        guard let entry = value as? [String: Any] else { return RoutingStats.Tokens() }
        var tokens = RoutingStats.Tokens()
        tokens.prompt = integer(entry["prompt"])
        tokens.completion = integer(entry["completion"])
        tokens.cached = integer(entry["cached"])
        tokens.reasoning = integer(entry["reasoning"])
        tokens.total = integer(entry["total"])
        return tokens
    }

    private static func models(_ value: Any?) -> [RoutingStats.ModelUsage] {
        guard let entry = value as? [String: Any] else { return [] }
        return entry.map { name, raw in
            let fields = raw as? [String: Any] ?? [:]
            return RoutingStats.ModelUsage(
                id: name,
                requests: integer(fields["calls"] ?? fields["requests"] ?? fields["total_requests"] ?? raw),
                errors: integer(fields["errors"] ?? fields["total_errors"]),
                tokens: integer((fields["tokens"] as? [String: Any])?["total"] ?? fields["total_tokens"]),
                latency: latency(fields["total_latency"])
            )
        }
        .sorted { $0.requests > $1.requests }
    }

    private static func latency(_ value: Any?) -> RoutingStats.Latency? {
        guard let entry = value as? [String: Any], integer(entry["count"]) > 0,
              entry["p50_ms"] != nil, entry["p99_ms"] != nil else { return nil }
        return RoutingStats.Latency(
            count: integer(entry["count"]),
            p50Milliseconds: double(entry["p50_ms"]),
            p99Milliseconds: double(entry["p99_ms"])
        )
    }

    private static func overhead(_ value: Any?) -> RoutingStats.Overhead {
        guard let entry = value as? [String: Any] else { return RoutingStats.Overhead() }
        var overhead = RoutingStats.Overhead()
        overhead.count = integer(entry["count"])
        overhead.averageMilliseconds = double(entry["avg_ms"])
        overhead.p50Milliseconds = double(entry["p50_ms"])
        overhead.p99Milliseconds = double(entry["p99_ms"])
        overhead.maximumMilliseconds = double(entry["max_ms"])
        return overhead
    }

    private static func integer(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text) ?? 0
        default: 0
        }
    }

    private static func double(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text) ?? 0
        default: 0
        }
    }
}
