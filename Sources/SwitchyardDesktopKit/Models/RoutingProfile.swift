import Foundation

/// A complete, user-confirmed routing setup: selected algorithm, its target
/// roles, and where the managed proxy listens.
package struct RoutingProfile: Codable, Equatable, Sendable {
    /// The port the existing NVIDIA scratch experiment owns. Never used by this app.
    package static let reservedPort = 4000
    package static let defaultPort = 4100
    package static let defaultHost = "127.0.0.1"
    /// Public model name Codex is pointed at; resolves to the generated `[routes.<id>]`.
    package static let defaultRouteID = "switchyard-desktop"

    /// Nil means use the native preset. A value is the complete algorithm body
    /// under [routes.main], including any nested native algorithm tables.
    package var additionalTargets: [TaskTier] = []
    package var nativeRouteOptions: String?
    package var judgeModelID: String?
    package var judgeNativeOptions: String?
    /// Advisor's review contract; separate from completion-target instructions.
    package var reviewerSystemPrompt: String?
    package var classifyTrigger: ClassifyTrigger = .everyRequest

    /// Reusable target descriptions and the judge's own prompt. Targets point
    /// at these; editing one reaches every target holding it.
    package var roles: [RoutingRole]

    package var provider: Provider
    /// `nil` until the user explicitly chooses a routing strategy.
    package var algorithm: RoutingAlgorithm?
    /// The roles for the selected algorithm. Stage routing must contain exactly
    /// Efficient then Capable; classifier routing contains two to six targets.
    package var tiers: [TaskTier]
    /// A classifier target selected to make the additional routing call.
    package var classifierTargetID: UUID?
    /// A classifier target selected when classification cannot choose a target.
    package var defaultTargetID: UUID?
    package var host: String
    package var port: Int
    package var routeID: String
    /// Where the proxy sends upstream traffic. Defaults to Codex's public API.
    package var upstreamBaseURL: String
    /// Discovered models Codex reports as accepting image input. The generated
    /// route may advertise image input only when every target is in this set.
    package var imageCapableModelIDs: Set<String>
    /// Largest context window each discovered model accepts, by model id. The
    /// generated route advertises the smallest of them, so Codex measures the
    /// conversation against a window every selectable target can serve.
    package var modelContextWindows: [String: Int]
    /// Keep Codex's summary preference when true; disable summaries when false.
    /// The stored name is retained for compatibility with saved profiles.
    package var advertisesReasoningSummaries: Bool
    /// Whether the route may advertise a window above `standardContextWindow`.
    ///
    /// OpenAI bills a prompt over 272k tokens at a premium — twice the input
    /// rate and one and a half times the output rate — so a user watching spend
    /// can hold the route at the standard window. This is the app-wide setting
    /// carried into the profile that renders the route; `WizardModel` owns it.
    package var allowsLongContext: Bool

    /// The prompt size above which OpenAI moves a request to its long-context
    /// rates.
    package static let standardContextWindow = 272_000

    package init(
        provider: Provider = .codex,
        algorithm: RoutingAlgorithm? = nil,
        tiers: [TaskTier]? = nil,
        classifierTargetID: UUID? = nil,
        defaultTargetID: UUID? = nil,
        host: String = RoutingProfile.defaultHost,
        port: Int = RoutingProfile.defaultPort,
        routeID: String = RoutingProfile.defaultRouteID,
        upstreamBaseURL: String? = nil,
        imageCapableModelIDs: Set<String> = [],
        modelContextWindows: [String: Int] = [:],
        advertisesReasoningSummaries: Bool = true,
        allowsLongContext: Bool = true,
        roles: [RoutingRole]? = nil
    ) {
        self.roles = roles ?? RoutingRole.builtIns
        self.provider = provider
        self.algorithm = algorithm
        self.classifyTrigger = algorithm == .composite ? .userTurn : .everyRequest
        self.tiers = tiers ?? Self.defaultTargets(for: algorithm)
        self.classifierTargetID = classifierTargetID
        self.defaultTargetID = defaultTargetID
        self.host = host
        self.port = port
        self.routeID = routeID
        self.upstreamBaseURL = upstreamBaseURL ?? provider.defaultUpstreamBaseURL
        self.imageCapableModelIDs = imageCapableModelIDs
        self.modelContextWindows = modelContextWindows
        self.advertisesReasoningSummaries = advertisesReasoningSummaries
        self.allowsLongContext = allowsLongContext
        // Explicit tiers carry their own wording; only the defaults start out
        // on the built-in roles.
        if tiers == nil { adoptDefaultRoles() }
        syncRolesIntoTargets()
    }

    private enum CodingKeys: String, CodingKey {
        case reviewerSystemPrompt
        case judgeModelID
        case judgeNativeOptions
        case additionalTargets
        case nativeRouteOptions
        case classifyTrigger
        case provider
        case algorithm
        case tiers
        case classifierTargetID
        case defaultTargetID
        case host
        case port
        case routeID
        case upstreamBaseURL
        case imageCapableModelIDs
        case modelContextWindows
        case roles
        case advertisesReasoningSummaries
        case allowsLongContext
    }

    /// Older builds stored only tiers and inferred the algorithm from their
    /// count. Decode those saved profiles once into an explicit compatible shape.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(Provider.self, forKey: .provider)
        let tiers = try container.decodeIfPresent([TaskTier].self, forKey: .tiers) ?? []
        let storedAlgorithm = try container.decodeIfPresent(RoutingAlgorithm.self, forKey: .algorithm)
        let algorithm = storedAlgorithm ?? (tiers.isEmpty ? nil : (tiers.count == 2 ? .stageRouter : .llmClassifier))

        additionalTargets = try container.decodeIfPresent([TaskTier].self, forKey: .additionalTargets) ?? []
        judgeModelID = try container.decodeIfPresent(String.self, forKey: .judgeModelID)
        judgeNativeOptions = try container.decodeIfPresent(String.self, forKey: .judgeNativeOptions)
        reviewerSystemPrompt = try container.decodeIfPresent(String.self, forKey: .reviewerSystemPrompt)
        nativeRouteOptions = try container.decodeIfPresent(String.self, forKey: .nativeRouteOptions)
        classifyTrigger = try container.decodeIfPresent(ClassifyTrigger.self, forKey: .classifyTrigger)
            ?? (algorithm == .composite ? .userTurn : .everyRequest)
        self.provider = provider
        self.algorithm = algorithm
        self.tiers = tiers.isEmpty ? Self.defaultTargets(for: algorithm) : tiers
        self.classifierTargetID = try container.decodeIfPresent(UUID.self, forKey: .classifierTargetID)
        self.defaultTargetID = try container.decodeIfPresent(UUID.self, forKey: .defaultTargetID)
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decode(Int.self, forKey: .port)
        self.routeID = try container.decode(String.self, forKey: .routeID)
        self.upstreamBaseURL =
            try container.decodeIfPresent(String.self, forKey: .upstreamBaseURL)
            ?? provider.defaultUpstreamBaseURL
        self.imageCapableModelIDs =
            try container.decodeIfPresent(Set<String>.self, forKey: .imageCapableModelIDs) ?? []
        // A profile saved before window discovery advertises no window, which
        // leaves Codex on its own default rather than guessing a larger one.
        self.modelContextWindows =
            try container.decodeIfPresent([String: Int].self, forKey: .modelContextWindows) ?? [:]
        // Older profiles leave the existing Codex summary preference unchanged.
        self.advertisesReasoningSummaries =
            try container.decodeIfPresent(Bool.self, forKey: .advertisesReasoningSummaries) ?? true
        // A profile saved before the setting existed keeps the window it had.
        self.allowsLongContext =
            try container.decodeIfPresent(Bool.self, forKey: .allowsLongContext) ?? true

        // Legacy classifier profiles had no explicit target choices. Retain the
        // previous behavior only while migrating their persisted selection.
        if storedAlgorithm == nil, algorithm == .llmClassifier {
            self.classifierTargetID = self.classifierTargetID ?? self.tiers.dropFirst().first?.id
            self.defaultTargetID = self.defaultTargetID ?? self.tiers.last?.id
        }
        let savedRoles = try container.decodeIfPresent([RoutingRole].self, forKey: .roles)
        // Provisional, so the recovery below can render this profile at all.
        // The judge's template is the one role a saved profile never lacks.
        roles = savedRoles?.isEmpty == false ? savedRoles! : [RoutingRole.builtInClassifier]
        NativeRoutingOptions.migrateLegacyReasoningSummaries(in: &self)
        // Before lifting roles, not after: a profile whose descriptions are
        // still frozen inside a captured route body reads as having none, and
        // the built-ins would go over the top of the user's own wording.
        SavedRoutingSetup.recoverGeneratedDescriptions(in: &self)

        // A profile saved before roles existed carries its wording on the
        // targets themselves. Lift it into roles rather than offering the
        // built-ins over the top of it: the descriptions are the user's, and a
        // target that loses its own would take the judge's reasoning with it.
        if savedRoles?.isEmpty != false {
            roles = Self.rolesLifted(from: self.tiers)
            for index in self.tiers.indices where index < roles.targets.count {
                self.tiers[index].roleID = roles.targets[index].id
            }
        }
        syncRolesIntoTargets()
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reviewerSystemPrompt, forKey: .reviewerSystemPrompt)
        try container.encode(additionalTargets, forKey: .additionalTargets)
        try container.encodeIfPresent(judgeModelID, forKey: .judgeModelID)
        try container.encodeIfPresent(judgeNativeOptions, forKey: .judgeNativeOptions)
        try container.encodeIfPresent(nativeRouteOptions, forKey: .nativeRouteOptions)
        try container.encode(classifyTrigger, forKey: .classifyTrigger)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(algorithm, forKey: .algorithm)
        try container.encode(tiers, forKey: .tiers)
        try container.encodeIfPresent(classifierTargetID, forKey: .classifierTargetID)
        try container.encodeIfPresent(defaultTargetID, forKey: .defaultTargetID)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(routeID, forKey: .routeID)
        try container.encode(upstreamBaseURL, forKey: .upstreamBaseURL)
        try container.encode(imageCapableModelIDs, forKey: .imageCapableModelIDs)
        try container.encode(modelContextWindows, forKey: .modelContextWindows)
        try container.encode(roles, forKey: .roles)
        try container.encode(advertisesReasoningSummaries, forKey: .advertisesReasoningSummaries)
        try container.encode(allowsLongContext, forKey: .allowsLongContext)
    }

    // MARK: - Roles

    /// One role per target, from wording the targets already carry.
    ///
    /// Targets that say nothing get the built-in ladder instead — an empty
    /// description is the one case where there is nothing to preserve.
    package static func rolesLifted(from tiers: [TaskTier]) -> [RoutingRole] {
        let described = tiers.filter { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !described.isEmpty else { return RoutingRole.builtIns }
        var lifted: [RoutingRole] = [RoutingRole.builtInClassifier]
        var taken: Set<String> = []
        for tier in tiers {
            var name = tier.displayName
            var suffix = 2
            while !taken.insert(name.lowercased()).inserted {
                name = "\(tier.displayName) \(suffix)"
                suffix += 1
            }
            // The role is this target's own wording, so it takes the target's
            // id: lifting the same saved profile twice has to give the same roles.
            lifted.append(RoutingRole(id: tier.id, name: name, text: tier.summary))
        }
        return lifted
    }

    package static func defaultTargets(for algorithm: RoutingAlgorithm?) -> [TaskTier] {
        switch algorithm {
        case .auto, .stageRouter, .capability, .escalation, .composite, .planExecute:
            TaskTier.stageRouterDefaults
        case .llmClassifier, .random, .prefillRouter:
            TaskTier.classifierDefaults
        case .advisor:
            [TaskTier(name: "Executor", summary: "Serves every visible turn."),
             TaskTier(name: "Advisor", summary: "Reviews the executor’s work.")]
        case .passthrough:
            [TaskTier(name: "Target", summary: "Serves every request.")]
        case .noop, nil:
            []
        }
    }

    /// Changing an algorithm always drops the incompatible role set and forces
    /// the user to make new, explicit assignments.
    package mutating func selectAlgorithm(_ algorithm: RoutingAlgorithm) {
        guard self.algorithm != algorithm else { return }
        self.algorithm = algorithm
        nativeRouteOptions = nil
        additionalTargets = []
        judgeModelID = nil
        judgeNativeOptions = nil
        reviewerSystemPrompt = nil
        classifyTrigger = algorithm == .composite ? .userTurn : .everyRequest
        tiers = Self.defaultTargets(for: algorithm)
        classifierTargetID = nil
        defaultTargetID = nil
        // Fresh default targets, so they start on the built-in ladder rather
        // than on blank fields nothing forces anyone to fill.
        adoptDefaultRoles()
        syncRolesIntoTargets()
    }

    /// Unique `[targets.<name>]` keys, positionally matching `tiers`.
    package var targetNames: [String] {
        if !tiers.isEmpty, tiers.allSatisfy({ $0.targetKey != nil }) {
            return tiers.compactMap(\.targetKey)
        }
        switch algorithm {
        case .auto, .stageRouter, .capability, .escalation, .composite, .planExecute:
            return ["efficient", "capable"]
        case nil:
            return []
        default:
            return tiers.targetNames
        }
    }

    package var allTargets: [TaskTier] { tiers + additionalTargets }

    package var allTargetNames: [String] {
        var names = targetNames
        for (index, target) in additionalTargets.enumerated() {
            if let key = target.targetKey {
                names.append(key)
                continue
            }
            let seed = target.slugSeed.isEmpty ? "extra\(index + 1)" : target.slugSeed
            var name = seed
            var suffix = 2
            while names.contains(name) || ["any", "judge"].contains(name) {
                name = "\(seed)\(suffix)"
                suffix += 1
            }
            names.append(name)
        }
        return names
    }

    package var classifierTargetName: String? {
        targetName(for: classifierTargetID)
    }

    /// The model the judge itself runs on.
    package var classifierModel: String? {
        if let judgeModelID, !judgeModelID.isEmpty { return judgeModelID }
        guard let classifierTargetID else { return nil }
        return tiers.first { $0.id == classifierTargetID }?.assignedModel
    }

    /// The route target that already serves the judge's model, if one does.
    ///
    /// Switchyard keeps one target per model id on a client, so a judge that
    /// repeats a target's model either needs a model name of its own or has to
    /// share that target.
    package var judgeSharedTargetName: String? {
        guard let classifierModel,
              let index = allTargets.firstIndex(where: { $0.assignedModel == classifierModel }),
              allTargetNames.indices.contains(index) else { return nil }
        return allTargetNames[index]
    }

    /// Whether the bundled LiteLLM answers the judge, so this app can publish a
    /// model name for it that no route target uses.
    package var publishesJudgeModelName: Bool { routesJudgeThroughLiteLLM || usesManagedLiteLLM }

    /// Whether a judge repeating a target's model asks for settings that target
    /// does not have. Switchyard refuses two such targets on one client, so the
    /// judge then needs a model name of its own.
    package var judgeNeedsDistinctSettings: Bool {
        guard let classifierModel,
              let shared = allTargets.first(where: { $0.assignedModel == classifierModel }) else {
            return false
        }
        return classifierRole?.effort != effort(of: shared)
            || judgeNativeOptions != shared.nativeOptions
            // The serving role's instructions must not replace the judge's
            // classification contract, even when both use the same effort.
            || role(of: shared)?.modelPrompt != nil
    }

    /// `[targets.<name>]` key of the judge-only target, when the judge needs a
    /// client of its own. Kept distinct from every routable target name.
    package var judgeTargetName: String? {
        guard routesJudgeThroughLiteLLM || judgeModelID != nil else { return nil }
        // An external upstream only serves the models it already knows, so a
        // judge repeating a target's model there runs as that target rather
        // than as a second target Switchyard would refuse.
        if !publishesJudgeModelName, judgeSharedTargetName != nil { return nil }
        let taken = Set(allTargetNames)
        var candidate = "judge"
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "judge\(suffix)"
            suffix += 1
        }
        return candidate
    }

    package var defaultTargetName: String? {
        targetName(for: defaultTargetID)
    }

    package func targetName(for id: UUID?) -> String? {
        guard let id,
              let index = tiers.firstIndex(where: { $0.id == id }),
              targetNames.indices.contains(index) else {
            return nil
        }
        return targetNames[index]
    }

    package func model(for tier: TaskTier) -> String? {
        tiers.first { $0.id == tier.id }?.assignedModel
    }

    /// Roles still missing a model assignment. Empty means the role step is complete.
    package var unassignedTiers: [TaskTier] {
        allTargets.filter { $0.assignedModel == nil }
    }

    /// Classifier roles still missing a description of their own. Stage routing
    /// hands no descriptions to a judge, so it never reports any.
    package var undescribedTiers: [TaskTier] {
        guard algorithm == .llmClassifier else { return [] }
        return tiers.filter(\.needsSummary)
    }

    package var canAddTier: Bool {
        algorithm?.hasVariableTargets == true && tiers.count < TaskTier.maximumCount
    }

    package var canRemoveTier: Bool {
        algorithm?.hasVariableTargets == true && tiers.count > TaskTier.minimumCount
    }

    package mutating func addTier() {
        guard canAddTier else { return }
        var tier = TaskTier.newTier(among: tiers)
        // The next role in the ladder that no target holds yet, so a new target
        // arrives described rather than blank.
        if let free = roles.targets.first(where: { role in !allTargets.contains { $0.roleID == role.id } }) {
            tier.roleID = free.id
        }
        tiers.append(tier)
        syncRolesIntoTargets()
    }

    package mutating func removeTier(id: UUID) {
        guard canRemoveTier else { return }
        tiers.removeAll { $0.id == id }
        if classifierTargetID == id { classifierTargetID = nil }
        if defaultTargetID == id { defaultTargetID = nil }
    }

    /// Clears every role that points at a model no longer available to the user.
    package mutating func clearAssignments(of modelID: String) {
        if judgeModelID == modelID { judgeModelID = nil }
        for index in tiers.indices where tiers[index].assignedModel == modelID {
            tiers[index].modelID = nil
        }
        for index in additionalTargets.indices where additionalTargets[index].assignedModel == modelID {
            additionalTargets[index].modelID = nil
        }
    }

    // MARK: - Roles

    /// The role a target holds, if it still exists.
    package func role(of tier: TaskTier) -> RoutingRole? { roles[id: tier.roleID] }

    /// The judge's prompt template. A profile always carries one.
    package var classifierRole: RoutingRole? { roles.classifier }

    /// `reasoning_effort` for a target, from its role.
    package func effort(of tier: TaskTier) -> RoutingRole.Effort? { role(of: tier)?.effort }

    /// Points the default targets at the built-in roles, in order.
    ///
    /// Only where the user defines the targets. Stage routing's two roles are
    /// fixed as Efficient and Capable, and a role would rename them out from
    /// under the server.
    private mutating func adoptDefaultRoles() {
        let offered = roles.targets
        guard algorithm?.hasVariableTargets == true, !offered.isEmpty else { return }
        for (index, role) in zip(tiers.indices, offered) {
            tiers[index].roleID = role.id
        }
    }

    /// Copies each role's wording onto the targets holding it.
    ///
    /// A target keeps its own `name` and `summary` rather than resolving them
    /// through the role on every read: the target key, the judge prompt, the
    /// saved setup and the adoption round-trip all already read a target, and
    /// they keep reading a target.
    package mutating func syncRolesIntoTargets() {
        for index in tiers.indices {
            guard let role = roles[id: tiers[index].roleID] else { continue }
            tiers[index].name = role.displayName
            tiers[index].summary = role.text
        }
        for index in additionalTargets.indices {
            guard let role = roles[id: additionalTargets[index].roleID] else { continue }
            additionalTargets[index].name = role.displayName
            additionalTargets[index].summary = role.text
        }
    }

    /// Gives a target a role, or takes it back to its own free-text wording.
    package mutating func assignRole(_ roleID: UUID?, to tierID: UUID) {
        guard let index = tiers.firstIndex(where: { $0.id == tierID }) else { return }
        tiers[index].roleID = roleID
        syncRolesIntoTargets()
    }

    package mutating func updateRole(_ role: RoutingRole) {
        guard let index = roles.firstIndex(where: { $0.id == role.id }) else { return }
        roles[index] = role
        syncRolesIntoTargets()
    }

    /// Removes a role. Targets holding it fall back to their own wording, which
    /// the role left behind, so nothing silently loses its description.
    package mutating func removeRole(id: UUID) {
        guard roles[id: id]?.kind == .target else { return }
        roles.removeAll { $0.id == id }
        for index in tiers.indices where tiers[index].roleID == id { tiers[index].roleID = nil }
        for index in additionalTargets.indices where additionalTargets[index].roleID == id {
            additionalTargets[index].roleID = nil
        }
    }

    /// Roles held by no target, so the wizard can say a role is unused rather
    /// than leaving the list looking applied.
    package func isRoleInUse(_ role: RoutingRole) -> Bool {
        role.kind == .classifier || allTargets.contains { $0.roleID == role.id }
    }

    /// Targets sharing a model that Switchyard cannot keep apart.
    ///
    /// It keeps one target per model id and llm client, so two that name the
    /// same model must ask for the same thing. Roles make this easy to reach:
    /// the same model under two roles is two different reasoning efforts, and
    /// the server rejects the whole file rather than picking one.
    package var conflictingDuplicateModels: [String] {
        var settings: [String: Set<String>] = [:]
        for tier in allTargets {
            guard let model = tier.assignedModel else { continue }
            let wanted = [effort(of: tier)?.rawValue ?? "", tier.nativeOptions ?? ""].joined(separator: "\u{1}")
            settings[model, default: []].insert(wanted)
        }
        return settings.filter { $0.value.count > 1 }.keys.sorted()
    }

    // MARK: - Validation

    /// Role-only errors shown while the user is configuring routing behavior.
    package var roleValidationErrors: [String] {
        guard let algorithm else {
            return ["Choose a routing algorithm."]
        }

        var errors: [String] = []
        switch algorithm {
        case .auto, .stageRouter, .capability, .escalation, .composite, .planExecute:
            if tiers.count != 2 {
                errors.append("Stage routing requires exactly Efficient and Capable roles.")
            } else if tiers.map(\.displayName) != ["Efficient", "Capable"] {
                errors.append("Stage routing roles must be Efficient followed by Capable.")
            }
        case .llmClassifier, .random, .prefillRouter:
            if tiers.count < TaskTier.minimumCount {
                errors.append("Classifier routing requires at least \(TaskTier.minimumCount) target roles.")
            }
            if tiers.count > TaskTier.maximumCount {
                errors.append("Classifier routing supports at most \(TaskTier.maximumCount) target roles.")
            }
        case .advisor:
            if tiers.count != 2 { errors.append("Advisor routing requires Executor and Advisor targets.") }
        case .passthrough:
            if tiers.isEmpty { errors.append("Passthrough requires a target.") }
        case .noop:
            break
        }
        if algorithm.requiresJudge, classifierModel == nil {
            errors.append(
                "Choose which model decides the routing — a target's model, or one of its own."
            )
        }
        if Set(allTargetNames).count != allTargetNames.count {
            errors.append("Native target keys must be unique.")
        }
        errors.append(contentsOf: NativeRoutingOptions.validationErrors(profile: self))

        for tier in unassignedTiers {
            errors.append("No model assigned to the \(tier.displayName) role.")
        }

        let conflicting = conflictingDuplicateModels
        if !conflicting.isEmpty {
            errors.append(
                "\(conflicting.formattedList()) is used by targets asking for different reasoning "
                    + "or settings. Switchyard keeps one target per model, so give them the same "
                    + "role settings or different models."
            )
        }

        if algorithm == .llmClassifier, nativeRouteOptions == nil {
            // Without the marker the judge is asked to choose between groups it
            // was never shown, and every turn falls through to the default.
            if let classifier = classifierRole, !classifier.rendersTargets {
                errors.append(
                    "The \(classifier.displayName) role must keep \(RoutingRole.targetsPlaceholder) "
                        + "where the group list belongs."
                )
            }
            if defaultTargetName == nil {
                errors.append("Choose the target that serves a turn the judge cannot place.")
            }
            // The judge picks a role by reading these descriptions and nothing
            // else. Left blank, every turn falls through to the default target
            // and the route serves one model.
            let undescribed = undescribedTiers
            if !undescribed.isEmpty {
                errors.append(
                    "Describe the work for "
                        + undescribed.map(\.displayName).formattedList()
                        + " — the classifier has nothing to tell the roles apart."
                )
            }
        }
        return errors
    }

    /// Reasons this profile cannot be applied, in the order the wizard should surface them.
    package var validationErrors: [String] {
        var errors: [String] = []
        if !provider.isSelectable {
            errors.append("\(provider.displayName) is not supported yet.")
        }
        errors.append(contentsOf: roleValidationErrors)
        if port == Self.reservedPort {
            errors.append("Port \(Self.reservedPort) is reserved and cannot be used.")
        }
        if !(1024...65535).contains(port) {
            errors.append("Port must be between 1024 and 65535.")
        }
        if !Self.isLoopbackHost(host) {
            errors.append("Host must be loopback-only (127.0.0.1, localhost, or ::1).")
        }
        if routeID.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Route id must not be empty.")
        }
        if !Self.isValidUpstreamURL(upstreamBaseURL) {
            errors.append(
                "Upstream base URL must be an absolute http(s) URL without credentials, query values, or fragments."
            )
        }
        return errors
    }

    package var isValid: Bool { validationErrors.isEmpty }

    /// The default endpoint belongs to the app. Any override is treated as an
    /// independently managed upstream and is never started or stopped here.
    package var usesManagedLiteLLM: Bool {
        algorithm != .noop && provider == .codex && upstreamBaseURL == provider.defaultUpstreamBaseURL
    }

    /// The direct ChatGPT upstream rejects the judge call Switchyard makes for a
    /// classifier route: it answers `400 Stream must be set to true`, and
    /// `400 Unsupported parameter: max_output_tokens` once streaming is set.
    /// Switchyard builds that request non-streaming and always bounds its
    /// output, so the judge fails on every turn and the route silently serves
    /// its default target. The bundled LiteLLM normalises both, so a direct
    /// profile keeps its served turns direct and sends only the judge there.
    package var routesJudgeThroughLiteLLM: Bool {
        provider == .codex
            && forwardsCallerCredential
            && classifierModel != nil
    }

    /// Whether the app has to start and supervise the bundled LiteLLM.
    package var needsManagedLiteLLM: Bool {
        usesManagedLiteLLM || routesJudgeThroughLiteLLM
    }

    /// Models the bundled LiteLLM must serve, or `nil` when it stays stopped.
    package var managedLiteLLMModels: [LiteLLMModel]? {
        if usesManagedLiteLLM {
            let served = allTargets.compactMap(\.assignedModel)
            var models = served.map { LiteLLMModel($0) }
            // A judge model of its own is served too, under the name the route
            // asks for — its model's, or one of its own when a target already
            // uses that model with other settings.
            if judgeModelID != nil, let classifierModel, let name = judgeModelName,
               !served.contains(name) {
                models.append(LiteLLMModel(name, servedBy: classifierModel))
            }
            return models
        }
        guard routesJudgeThroughLiteLLM,
              let classifierModel,
              let name = judgeModelName else { return nil }
        return [LiteLLMModel(name, servedBy: classifierModel)]
    }

    /// The model id written on the judge's own target.
    ///
    /// A judge on its own `[llm_clients]` entry needs a model id no route
    /// target uses: Switchyard keys execution by model id and rejects one id
    /// reached through two clients. LiteLLM publishes that name and calls the
    /// real model behind it, so the judge keeps running the model the user
    /// chose.
    package var judgeModelName: String? {
        guard let classifierModel else { return nil }
        // A judge on the route's own client only needs a name of its own when
        // a target already uses that model.
        let needsOwnName = routesJudgeThroughLiteLLM
            || (usesManagedLiteLLM && judgeSharedTargetName != nil && judgeNeedsDistinctSettings)
        guard needsOwnName, publishesJudgeModelName else { return classifierModel }
        let taken = Set(allTargets.compactMap(\.assignedModel))
        var candidate = "judge-\(classifierModel)"
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "judge\(suffix)-\(classifierModel)"
            suffix += 1
        }
        return candidate
    }

    /// A loopback proxy such as a developer-run LiteLLM owns its own
    /// authentication. Only a direct remote upstream receives the credential
    /// supplied by the caller.
    package var forwardsCallerCredential: Bool {
        guard let host = URLComponents(string: upstreamBaseURL)?.host else { return false }
        return !Self.isLoopbackHost(host)
    }

    package static func isLoopbackHost(_ host: String) -> Bool {
        switch host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "127.0.0.1", "localhost", "::1":
            return true
        default:
            return false
        }
    }

    package static func isValidUpstreamURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return true
    }

    /// True only when every assigned target accepts image input. Switchyard
    /// advertises image support per route, and Codex drops an attached image
    /// before sending when the route reads text-only — so a mixed route has to
    /// stay text-only rather than lose the image at whichever target cannot see.
    package var advertisesImageInput: Bool {
        let assigned = allTargets.compactMap(\.assignedModel)
        guard !assigned.isEmpty, assigned.count == allTargets.count else { return false }
        return assigned.allSatisfy { imageCapableModelIDs.contains($0) }
    }

    /// Assigned targets that cannot take an image, for explaining the above.
    package var textOnlyAssignedModels: [String] {
        allTargets.compactMap(\.assignedModel).filter { !imageCapableModelIDs.contains($0) }
    }

    /// The window the generated route advertises, or nil to leave Codex on its
    /// own default.
    ///
    /// Codex applies one window to a whole conversation while the route may
    /// send any turn to any target, so the only window that is safe for every
    /// turn is the smallest one the selectable targets accept. An unknown
    /// target means the smallest is unknown too — advertising the rest would
    /// over-promise — so discovery has to have covered them all. The judge is
    /// left out: switchyard writes its prompt itself, and it is never a
    /// destination for the conversation Codex is measuring.
    ///
    /// With long context off the window stops at `standardContextWindow`, so
    /// Codex compacts the conversation before a prompt reaches the premium
    /// rates. No window at all is already Codex's own 272k default.
    package var routeContextWindow: Int? {
        guard let window = smallestModelContextWindow else { return nil }
        return allowsLongContext ? window : min(window, Self.standardContextWindow)
    }

    /// The smallest window the assigned models accept, before the long-context
    /// setting is applied.
    private var smallestModelContextWindow: Int? {
        let assigned = allTargets.compactMap(\.assignedModel)
        guard !assigned.isEmpty, assigned.count == allTargets.count else { return nil }
        let windows = assigned.map { modelContextWindows[$0] }
        guard !windows.contains(where: { $0 == nil }) else { return nil }
        return windows.compactMap { $0 }.min()
    }

    /// True when the models would take more than the route advertises and the
    /// long-context setting is what holds the window at the standard size.
    package var longContextIsBlocked: Bool {
        guard !allowsLongContext, let window = smallestModelContextWindow else { return false }
        return window > Self.standardContextWindow
    }

    /// Assigned models holding the route down to `routeContextWindow`, so the
    /// UI can name what to drop to raise it. Empty when every target agrees, or
    /// when the long-context setting is what sets the window.
    package var contextWindowCappingModels: [String] {
        guard !longContextIsBlocked, let window = smallestModelContextWindow else { return [] }
        let assigned = allTargets.compactMap(\.assignedModel)
        guard assigned.contains(where: { modelContextWindows[$0] != window }) else { return [] }
        var seen = Set<String>()
        return assigned.filter { modelContextWindows[$0] == window && seen.insert($0).inserted }
    }

    /// Base URL Codex should be pointed at once the proxy is running.
    package var proxyBaseURL: String {
        let urlHost = host.contains(":") ? "[\(host)]" : host
        return "http://\(urlHost):\(port)/v1"
    }
}
