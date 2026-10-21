import Foundation
import TOMLKit

/// Switchyard advertises a route window to clients; it does not enforce it or
/// assign it to the upstream targets. Keep it separate from model capacities.
package enum SwitchyardRouteContext {
    package static func configuredWindows(at url: URL) -> [String: Int] {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let document = try? TOMLTable(string: text),
              let routes = document["routes"]?.table else { return [:] }
        var windows: [String: Int] = [:]
        for key in routes.keys {
            guard let route = routes[key]?.table,
                  let id = route["id"]?.string,
                  let limit = route["context_window"]?.int, limit > 0 else { continue }
            windows[id] = limit
        }
        return windows
    }

    package static func advertisedWindows(in payload: [String: Any]) -> [String: Int] {
        guard let models = payload["data"] as? [[String: Any]] else { return [:] }
        var windows: [String: Int] = [:]
        for model in models {
            guard let id = model["id"] as? String,
                  let capabilities = model["capabilities"] as? [String: Any],
                  let number = capabilities["context_window"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let limit = Int(number.stringValue), limit > 0 else { continue }
            windows[id] = limit
        }
        return windows
    }
}
