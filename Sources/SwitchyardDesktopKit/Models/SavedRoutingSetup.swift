import Foundation
import TOMLKit

/// A reusable, non-sensitive setup. This is deliberately separate from
/// `ActiveRoutingSession`, whose lifetime and deletion rules protect Codex
/// recovery after an interrupted route.
package struct SavedRoutingSetup: Codable, Equatable, Sendable {
    package var profile: RoutingProfile
    package let discoveredModels: [CodexSubscriptionModel]
    package let binaryPathOverride: String
    package let savedAt: Date

    package init(
        profile: RoutingProfile, discoveredModels: [CodexSubscriptionModel], binaryPathOverride: String,
        savedAt: Date
    ) {
        self.profile = profile
        self.discoveredModels = discoveredModels
        self.binaryPathOverride = binaryPathOverride
        self.savedAt = savedAt
    }

    package var isUsable: Bool {
        guard profile.isValid else { return false }
        let available = Set(discoveredModels.map(\.id))
        let assigned = profile.allTargets.compactMap(\.assignedModel)
        return assigned.count == profile.allTargets.count
            && assigned.allSatisfy(available.contains)
            && (profile.judgeModelID.map(available.contains) ?? true)
    }

    /// One-time migration for builds that already generated `routes.toml`
    /// before reusable setup persistence existed.
    package static func migrateGeneratedConfig(from fileURL: URL) throws -> SavedRoutingSetup {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let table = try TOMLTable(string: text)
        let document = try TOMLDecoder().decode(GeneratedDocument.self, from: table)
        guard let route = document.routes["main"],
              let routeTable = table["routes"]?.table?["main"]?.table,
              let algorithm = RoutingAlgorithm(rawValue:
                route.type == "llm_classifier" && route.mode == "capability" ? "capability" :
                route.type == "llm_classifier" && route.mode == "escalation" ? "escalation" : route.type) else {
            throw MigrationFailure.unsupportedRoute
        }

        let targetNames: [String]
        switch algorithm {
        case .stageRouter, .auto, .capability, .escalation, .composite, .planExecute:
            guard let efficient = route.efficient_target ?? route.weak_target ?? route.stage?.efficient_target,
                  let capable = route.capable_target ?? route.strong_target ?? route.stage?.capable_target else {
                throw MigrationFailure.incompleteRoute
            }
            targetNames = [efficient, capable]
        case .llmClassifier:
            // A file written before Switchyard's model groups listed its
            // selectable targets inline; `models.any` replaced that list.
            guard let targets = route.targets ?? route.models?[Self.anyGroup],
                  targets.count >= TaskTier.minimumCount else {
                throw MigrationFailure.incompleteRoute
            }
            targetNames = Array(targets.prefix(TaskTier.maximumCount))
        case .random, .prefillRouter:
            guard let targets = route.targets else { throw MigrationFailure.incompleteRoute }
            targetNames = Array(targets.prefix(TaskTier.maximumCount))
        case .advisor:
            guard let executor = route.executor_target, let advisor = route.advisor_target else {
                throw MigrationFailure.incompleteRoute
            }
            targetNames = [executor, advisor]
        case .passthrough:
            guard let target = route.target else { throw MigrationFailure.incompleteRoute }
            targetNames = [target]
        case .noop:
            targetNames = []
        }

        let generatedTargets = try targetNames.map { name -> GeneratedTarget in
            guard let target = document.targets[name] else {
                throw MigrationFailure.incompleteRoute
            }
            return target
        }
        guard let clientName = generatedTargets.first?.llm_client ?? document.llm_clients.keys.sorted().first,
              generatedTargets.allSatisfy({ $0.llm_client == clientName }),
              let client = document.llm_clients[clientName] else {
            throw MigrationFailure.incompleteRoute
        }

        let tiers = zip(targetNames, generatedTargets).enumerated().map { index, pair in
            let (name, target) = pair
            let displayName: String
            if algorithm.hasTierPair {
                displayName = index == 0 ? "Efficient" : "Capable"
            } else {
                displayName = name
                    .split(separator: "_")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
            }
            var tier = TaskTier(name: displayName, summary: "", modelID: target.id)
            tier.targetKey = name
            if let fields = table["targets"]?.table?[name]?.table {
                fields.remove(at: "id")
                fields.remove(at: "llm_client")
                if !fields.keys.isEmpty { tier.nativeOptions = NativeRoutingOptions.body(fields, path: ["targets", name]) }
            }
            return tier
        }

        var profile = RoutingProfile(
            provider: .codex,
            algorithm: algorithm,
            tiers: tiers,
            routeID: route.id,
            upstreamBaseURL: client.base_url
        )
        let judgeName = route.classifier_target ?? route.models?[Self.judgeGroup]?.first
            ?? route.classifier?.target ?? route.advisor_target
            ?? route.subagents?.models?[Self.judgeGroup]?.first
        profile.classifierTargetID = targetID(named: judgeName, in: targetNames, tiers: tiers)
        if profile.classifierTargetID == nil, let judgeName, let judge = document.targets[judgeName] {
            // Generated judge aliases use the same model as a role or a separate
            // discovered judge model. Keep the native alias and its settings.
            guard judgeName == "judge" else { throw MigrationFailure.incompleteRoute }
            profile.judgeModelID = judge.id
            if let fields = table["targets"]?.table?[judgeName]?.table {
                fields.remove(at: "id")
                fields.remove(at: "llm_client")
                profile.judgeNativeOptions = NativeRoutingOptions.body(fields, path: ["targets", judgeName])
            }
        }
        for name in document.targets.keys.sorted() where !targetNames.contains(name) && name != judgeName {
            guard let target = document.targets[name], target.llm_client == clientName else {
                throw MigrationFailure.incompleteRoute
            }
            var extra = TaskTier(name: name, summary: "", modelID: target.id)
            extra.targetKey = name
            if let fields = table["targets"]?.table?[name]?.table {
                fields.remove(at: "id")
                fields.remove(at: "llm_client")
                extra.nativeOptions = NativeRoutingOptions.body(fields, path: ["targets", name])
            }
            profile.additionalTargets.append(extra)
        }
        profile.defaultTargetID = targetID(named: route.default_target, in: targetNames, tiers: tiers)
        if let trigger = route.classify_trigger ?? route.classifier?.classify_trigger {
            profile.classifyTrigger = trigger
        }
        // Preserve the native prompt, groups, policy, thresholds, trigger and
        // nested subagent settings instead of reconstructing them from labels.
        if algorithm != .llmClassifier || route.models != nil {
            routeTable.remove(at: "id")
            profile.nativeRouteOptions = NativeRoutingOptions.body(routeTable, path: ["routes", "main"])
        } else {
            // Legacy generated classifiers predate model groups and need a fresh
            // description before they can produce a useful custom prompt.
            for index in profile.tiers.indices {
                profile.tiers[index].summary = "Restored legacy target \(targetNames[index])."
            }
        }
        if route.vision == true {
            profile.imageCapableModelIDs = Set(generatedTargets.map(\.id))
        }
        // Preserve the old opt-out as a client setting, removing the server key.
        profile.advertisesReasoningSummaries = route.reasoning_summaries ?? true
        NativeRoutingOptions.migrateLegacyReasoningSummaries(in: &profile)
        recoverGeneratedDescriptions(in: &profile)

        var models = generatedTargets.enumerated().map { index, target in
            CodexSubscriptionModel(
                id: target.id,
                displayName: nil,
                isDefault: index == 0,
                supportsImages: route.vision == true
            )
        }
        models += profile.additionalTargets.compactMap { target in
            target.assignedModel.map { CodexSubscriptionModel(id: $0, displayName: nil, isDefault: false) }
        }
        if let judge = profile.judgeModelID, !models.contains(where: { $0.id == judge }) {
            models.append(CodexSubscriptionModel(id: judge, displayName: nil, isDefault: false))
        }
        let setup = SavedRoutingSetup(
            profile: profile,
            discoveredModels: Array(Dictionary(grouping: models, by: \.id).values.compactMap(\.first)),
            binaryPathOverride: "",
            savedAt: Date()
        )
        guard setup.isUsable else { throw MigrationFailure.incompleteRoute }
        return setup
    }

    private static func targetID(
        named name: String?,
        in targetNames: [String],
        tiers: [TaskTier]
    ) -> UUID? {
        guard let name, let index = targetNames.firstIndex(of: name) else { return nil }
        return tiers[index].id
    }

    /// Group names Switchyard reserves in a route's `models` table.
    private static let anyGroup = "any"
    private static let judgeGroup = "judge"

    private enum MigrationFailure: Error {
        case unsupportedRoute
        case incompleteRoute
    }

    /// Puts a generated classifier's target descriptions back into their fields.
    ///
    /// Adoption otherwise keeps the whole route body verbatim. That leaves the
    /// description fields empty while the prompt naming those same targets is
    /// frozen in an opaque blob, so removing a target leaves the prompt, the
    /// fallback and the model groups naming one that no longer exists and the
    /// server rejects the route.
    ///
    /// The descriptions only move when re-rendering the profile reproduces the
    /// captured route exactly: anything this app cannot reproduce — a
    /// hand-written prompt, a policy it does not generate — stays native and
    /// untouched, fields and all.
    package static func recoverGeneratedDescriptions(in profile: inout RoutingProfile) {
        guard profile.algorithm == .llmClassifier,
              let options = profile.nativeRouteOptions,
              let captured = route(in: "[routes.main]\n" + options),
              let prompt = captured["prompt"]?.string else { return }

        // `judgePrompt` renders one "- <target key>: <description>" per target.
        var descriptions: [String: String] = [:]
        for line in prompt.split(separator: "\n") where line.hasPrefix("- ") {
            let entry = line.dropFirst(2)
            guard let separator = entry.range(of: ": ") else { continue }
            descriptions[String(entry[..<separator.lowerBound])] = String(entry[separator.upperBound...])
        }
        guard !descriptions.isEmpty else { return }

        let native = profile
        for index in profile.tiers.indices {
            guard let key = profile.tiers[index].targetKey,
                  let description = descriptions[key] else { continue }
            profile.tiers[index].summary = description
        }
        profile.nativeRouteOptions = nil

        guard let rendered = try? SwitchyardConfigWriter.render(profile: profile),
              let generated = route(in: rendered),
              routingShape(generated) == routingShape(captured) else {
            profile = native
            return
        }
    }

    private static func route(in toml: String) -> TOMLTable? {
        try? TOMLTable(string: toml)["routes"]?.table?["main"]?.table
    }

    /// A route's routing decisions, comparable regardless of key order.
    ///
    /// The keys removed here are not routing decisions: `id` is stripped from a
    /// captured body, and the window and image support are resolved from the
    /// account and the server build every time the route is written.
    private static func routingShape(_ route: TOMLTable) -> NSDictionary? {
        for key in ["id", "vision", "context_window", "reasoning_summaries"] {
            route.remove(at: key)
        }
        guard let json = try? route.convert(to: .json).data(using: .utf8),
              let shape = try? JSONSerialization.jsonObject(with: json) as? NSDictionary else {
            return nil
        }
        return shape
    }

    private struct GeneratedDocument: Decodable {
        package let llm_clients: [String: GeneratedClient]
        package let targets: [String: GeneratedTarget]
        package let routes: [String: GeneratedRoute]
    }

    private struct GeneratedClient: Decodable {
        package let base_url: String
    }

    private struct GeneratedTarget: Decodable {
        package let id: String
        package let llm_client: String
    }

    private struct GeneratedStage: Decodable {
        package let efficient_target: String
        package let capable_target: String
    }

    private struct GeneratedClassifier: Decodable {
        package let target: String
        package let classify_trigger: ClassifyTrigger?
    }

    private struct GeneratedSubagents: Decodable {
        package let models: [String: [String]]?
    }

    private struct GeneratedRoute: Decodable {
        package let id: String
        package let type: String
        package let mode: String?
        package let target: String?
        package let strong_target: String?
        package let weak_target: String?
        package let executor_target: String?
        package let advisor_target: String?
        package let classify_trigger: ClassifyTrigger?
        package let stage: GeneratedStage?
        package let classifier: GeneratedClassifier?
        package let subagents: GeneratedSubagents?
        package let efficient_target: String?
        package let capable_target: String?
        package let targets: [String]?
        package let models: [String: [String]]?
        package let classifier_target: String?
        package let default_target: String?
        package let vision: Bool?
        package let reasoning_summaries: Bool?
    }
}

package protocol SavedRoutingSetupStoring: AnyObject {
    func load() throws -> SavedRoutingSetup?
    func save(_ setup: SavedRoutingSetup) throws
    func clear() throws
}

package final class SavedRoutingSetupStore: SavedRoutingSetupStoring {
    package static var defaultURL: URL {
        UserDataLocations.supportDirectory.appendingPathComponent("saved-routing-setup.json")
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package init(
        fileURL: URL = SavedRoutingSetupStore.defaultURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    package func load() throws -> SavedRoutingSetup? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        // Decoding a profile recovers descriptions frozen in a route body and
        // lifts them into roles; nothing more is needed here.
        return try decoder.decode(SavedRoutingSetup.self, from: Data(contentsOf: fileURL))
    }

    package func save(_ setup: SavedRoutingSetup) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(setup).write(to: fileURL, options: .atomic)
    }

    package func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
