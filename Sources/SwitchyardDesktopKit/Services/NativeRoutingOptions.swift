import Foundation
import TOMLKit

/// Checks only ownership of generated TOML tables. Switchyard validates every
/// algorithm field, threshold, prompt contract and target reference itself.
package enum NativeRoutingOptions {
    /// Older app builds wrote this client preference into the server route.
    /// Move it out on restore without changing prompts or nested route fields.
    package static func migrateLegacyReasoningSummaries(in profile: inout RoutingProfile) {
        guard let options = profile.nativeRouteOptions,
              let document = try? TOMLTable(string: "[routes.main]\n" + options),
              let route = document["routes"]?.table?["main"]?.table,
              let enabled = route["reasoning_summaries"]?.bool else { return }
        profile.advertisesReasoningSummaries = enabled
        route.remove(at: "reasoning_summaries")
        profile.nativeRouteOptions = body(route, path: ["routes", "main"])
    }

    /// Serialize through the TOML parser so multiline prompts retain their
    /// values, including quotes and literal delimiters, when restoring a setup.
    package static func body(_ table: TOMLTable, path: [String]) -> String {
        guard !table.keys.isEmpty else { return "" }
        var wrapped = table
        for key in path.reversed() { wrapped = TOMLTable([key: wrapped]) }
        let text = wrapped.convert()
        let header = "[" + path.joined(separator: ".") + "]"
        // A table containing only nested tables may have no standalone header.
        // Keep the fully qualified child headers in that case.
        guard text.hasPrefix(header + "\n") else { return text }
        return String(text.dropFirst(header.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Route keys whose value names a target.
    private static let targetKeys: Set<String> = [
        "target", "default_target", "classifier_target", "strong_target", "weak_target",
        "efficient_target", "capable_target", "executor_target", "advisor_target",
    ]

    /// Every target a native route body names, including its model groups.
    ///
    /// A native body is frozen at the moment it was captured, so removing or
    /// renaming a target leaves it pointing at one that no longer exists. Left
    /// to the dry run, that surfaces at Review as an opaque server rejection;
    /// named here, it surfaces on the step that caused it.
    package static func referencedTargets(in route: TOMLTable) -> Set<String> {
        var names: Set<String> = []
        for key in route.keys {
            guard let value = route[key] else { continue }
            if targetKeys.contains(key), let name = value.string {
                names.insert(name)
            } else if key == "targets", let array = value.array {
                names.formUnion((0..<array.count).compactMap { array[$0]?.string })
            } else if key == "models", let groups = value.table {
                for group in groups.keys {
                    guard let array = groups[group]?.array else { continue }
                    names.formUnion((0..<array.count).compactMap { array[$0]?.string })
                }
            } else if let nested = value.table {
                names.formUnion(referencedTargets(in: nested))
            }
        }
        return names
    }

    package static func validationErrors(profile: RoutingProfile) -> [String] {
        var errors: [String] = []
        if let options = profile.nativeRouteOptions {
            do {
                let document = try TOMLTable(string: "[routes.main]\n" + options)
                guard Set(document.keys) == ["routes"],
                      let routes = document["routes"]?.table,
                      Set(routes.keys) == ["main"],
                      let route = routes["main"]?.table,
                      route["id"] == nil,
                      route["type"]?.string == profile.algorithm?.serverType else {
                    return ["Route options must configure only [routes.main], keep the selected type, and omit id."]
                }
                let known = Set(profile.allTargetNames + [profile.judgeTargetName].compactMap { $0 })
                let missing = referencedTargets(in: route).subtracting(known).sorted()
                if !missing.isEmpty {
                    errors.append(
                        "Route options name \(missing.formattedList()), which no target role "
                            + "provides any more. Update the options or restore the native preset."
                    )
                }
            } catch {
                errors.append("Invalid route options: \(error.localizedDescription)")
            }
        }
        var targetOptions = zip(profile.allTargets, profile.allTargetNames).compactMap { tier, name in
            tier.nativeOptions.map { (name, $0) }
        }
        if let judge = profile.judgeTargetName, let options = profile.judgeNativeOptions {
            targetOptions.append((judge, options))
        }
        for (name, options) in targetOptions {
            do {
                let document = try TOMLTable(string: "[targets.\(name)]\n" + options)
                guard Set(document.keys) == ["targets"],
                      let targets = document["targets"]?.table,
                      Set(targets.keys) == [name],
                      let target = targets[name]?.table,
                      target["id"] == nil, target["llm_client"] == nil else {
                    errors.append("Options for \(name) must configure only that target and omit id and llm_client.")
                    continue
                }
            } catch {
                errors.append("Invalid options for \(name): \(error.localizedDescription)")
            }
        }
        return errors
    }
}
