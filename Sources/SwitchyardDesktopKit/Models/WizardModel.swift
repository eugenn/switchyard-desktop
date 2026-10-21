import Foundation
import Observation

/// Drives the wizard: which step is showing, the profile being built, and the
/// apply/revert sequence that touches the filesystem and the proxy process.
@MainActor
@Observable
package final class WizardModel {
    package enum Step: Int, CaseIterable, Identifiable {
        /// Reading the Codex setup and listing its models are one question —
        /// "what can this account route?" — so they are one step.
        case provider, tiers, confirm

        package var id: Int { rawValue }

        package var title: String {
            switch self {
            case .provider: return "Codex account"
            case .tiers: return "Routing"
            case .confirm: return "Review & start"
            }
        }
    }

    package enum ApplyState: Equatable {
        case idle
        case working(String)
        case applied(configPath: String, profilePath: String)
        case failed(String)

        /// The step in progress, for naming where a failed apply got to.
        package var workingMessage: String? {
            if case .working(let message) = self { return message }
            return nil
        }
    }

    /// What a launch found left over from a run that ended without cleaning up,
    /// and what it did about it.
    ///
    /// Nothing here ever blocks Start. The only leftovers this app can produce
    /// are its own generated profile — which Start overwrites — and, for one
    /// launch after an upgrade, a configuration an older version had patched.
    package enum RecoveryState: Equatable {
        case none
        /// A leftover already dealt with at launch. This only says what changed.
        case cleanedUp(String)
        /// A leftover this launch could not remove, which the user has to look
        /// at. Routing still starts: Start replaces the generated profile.
        case warning(String)

        package var needsAttention: Bool {
            if case .warning = self { return true }
            return false
        }
    }

    package enum DiscoveryState: Equatable, Sendable {
        case idle
        case loading
        case ready([CodexSubscriptionModel])
        case setupFailed(CodexSetupReader.Failure)
        case discoveryFailed(CodexModelDiscovery.Failure)
        case unexpectedFailure

        package var models: [CodexSubscriptionModel] {
            guard case .ready(let models) = self else { return [] }
            return models
        }

        package var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        package var blockingMessage: String {
            switch self {
            case .idle:
                return "Check your Codex setup before continuing."
            case .loading:
                return "Checking your Codex subscription…"
            case .ready:
                return ""
            case .setupFailed(let failure):
                return failure.errorDescription ?? "Codex must be configured before continuing."
            case .discoveryFailed(let failure):
                return failure.errorDescription ?? "Model discovery failed. Try again."
            case .unexpectedFailure:
                return "switchyard-desktop could not check your Codex subscription. Try again."
            }
        }
    }

    /// One discovery attempt's full outcome: the models plus the context the
    /// setup step needs to explain which stage passed.
    package struct DiscoveryOutcome: Sendable {
        package let state: DiscoveryState
        package let setup: CodexSetup?
        package let cliVersion: String?
        /// Largest window per model id. Empty when Codex could not render its
        /// catalog, which leaves the route advertising no window at all.
        package var contextWindows: [String: Int] = [:]
        /// `reasoning_effort` levels per model id, for checking a role's.
        package var supportedEfforts: [String: [String]] = [:]
    }

    package var step: Step = .provider
    package var profile: RoutingProfile {
        didSet {
            // A saved setup, a preset or a restored profile is a setup, not
            // an account inventory. Any of them can predate window discovery,
            // and letting one take over unnoticed would drop the route's window
            // and put Codex back on its own 272k default.
            // The library is where a role is written, so a profile arriving
            // from disk, from a preset or from a draft takes the library's
            // wording for every role it recognises rather than carrying a copy
            // that stopped matching what this screen shows.
            syncRolesFromLibrary()
            // The setting is the user's, not the setup's: a profile taking over
            // carries whatever it was saved with.
            if profile.allowsLongContext != allowsLongContext {
                profile.allowsLongContext = allowsLongContext
            }
            guard !discoveredContextWindows.isEmpty,
                  profile.modelContextWindows != discoveredContextWindows else { return }
            profile.modelContextWindows = discoveredContextWindows
        }
    }
    /// The Settings switch for prompts past OpenAI's 272k-token threshold, which
    /// bills them at a premium. Applied to the route the next time routing
    /// starts, because the window lives in the generated route file.
    package var allowsLongContext: Bool {
        didSet {
            guard allowsLongContext != oldValue else { return }
            profile.allowsLongContext = allowsLongContext
            persistPreferences()
        }
    }
    /// Why the preference could not be saved, if it could not.
    package private(set) var preferencesError: String?
    /// Guards the write the role sync makes back into `profile`.
    private var isSyncingRolesFromLibrary = false
    /// Windows from the most recent discovery, kept apart from the profile so
    /// they survive a profile being replaced wholesale.
    private var discoveredContextWindows: [String: Int] = [:]
    /// `reasoning_effort` levels per model id, from the same discovery. Not
    /// stored in the profile: it describes the account, and a stale copy would
    /// warn about a level the model has since gained.
    package private(set) var supportedEfforts: [String: [String]] = [:]
    /// Optional override for the `switchyard-server` path, from the review step.
    package var binaryPathOverride: String = ""
    package private(set) var applyState: ApplyState = .idle
    /// Whether the work `applyState` reports is a stop rather than a start, so
    /// a window that did not ask for it still shows which way routing is going.
    package private(set) var isStopping = false
    package private(set) var readiness: RoutingReadiness
    package private(set) var recoveryState: RecoveryState = .none
    package private(set) var discoveryState: DiscoveryState = .idle
    /// Non-sensitive Codex settings from the last successful read.
    package private(set) var codexSetup: CodexSetup?
    package private(set) var codexCLIVersion: String?
    package private(set) var discoveredAt: Date?
    package private(set) var hasSavedSetup = false
    /// Last successfully persisted routing setup.
    package private(set) var lastSavedSetup: SavedRoutingSetup?
    package private(set) var savedSetupWarning: String?
    /// Every role this Mac knows. A setup takes
    /// copies of the ones it uses; this is where they are written.
    package private(set) var roleLibrary: RoleLibrary = .shipped
    /// Why the library could not be written, if a save failed. The edit is
    /// still in memory, so the screen keeps working and says what is wrong.
    package private(set) var roleLibraryError: String?
    /// What the last reclaim actually stopped, when it stopped anything. Nil is
    /// the ordinary case: nothing was left behind.
    package private(set) var leftoverNotice: String?
    /// How the generated Codex profile stopped matching the running route, when
    /// something has changed or removed it. Nil while the two agree.
    package private(set) var codexDrift: CodexRouteDrift?
    /// Set when routing started but the record used to clean up after a crash
    /// could not be written. Routing itself is unaffected.
    package private(set) var sessionRecordWarning: String?
    /// Why the last repair of that drift did not go through, if one failed.
    package private(set) var codexRepairError: String?
    /// The review step's consent gate.
    package var acknowledgedSideEffects = false
    package var shouldConfirmQuit = false

    package let processManager: SwitchyardProcessManager
    /// The shared beat on which every window recalculates its derived figures,
    /// such as the session cost, together with its statistics.
    package let recalculationSignal = RecalculationSignal()
    package let routingConfigPath: URL
    /// The user's own Codex configuration. Read for discovery, never written.
    package let codexConfigPath: URL
    /// The layer this app generates beside it, and the only Codex file it owns.
    package let codexProfilePath: URL
    private let readinessChecker: any RoutingReadinessChecking
    private let sessionStore: any ActiveRoutingSessionStoring
    private let savedSetupStore: any SavedRoutingSetupStoring
    private let roleLibraryStore: any RoleLibraryStoring
    private let preferencesStore: any AppPreferencesStoring
    private let setupReader: any CodexSetupReading
    private let modelDiscovery: any CodexModelDiscovering
    private let cliVersionProbe: @Sendable () -> String?
    private let diagnostics: DiagnosticLog
    private var activeSession: ActiveRoutingSession?
    private var codexSelectionWatch: Task<Void, Never>?

    package init(
        processManager: SwitchyardProcessManager = SwitchyardProcessManager(),
        readinessChecker: any RoutingReadinessChecking = RoutingReadinessChecker(),
        routingConfigPath: URL = SwitchyardConfigWriter.defaultConfigURL,
        codexConfigPath: URL = CodexSetupReader.defaultConfigURL,
        codexProfilePath: URL = CodexProfileWriter.defaultProfileURL,
        sessionStore: any ActiveRoutingSessionStoring = ActiveRoutingSessionStore(),
        savedSetupStore: any SavedRoutingSetupStoring = SavedRoutingSetupStore(),
        roleLibraryStore: any RoleLibraryStoring = RoleLibraryStore(),
        preferencesStore: any AppPreferencesStoring = AppPreferencesStore(),
        setupReader: any CodexSetupReading = CodexSetupReader(),
        modelDiscovery: any CodexModelDiscovering = CodexModelDiscovery(),
        cliVersionProbe: @escaping @Sendable () -> String? = { CodexCLIProbe.version() },
        restoreSavedSetup: Bool? = nil,
        diagnostics: DiagnosticLog = .shared
    ) {
        self.profile = RoutingProfile()
        self.processManager = processManager
        self.readinessChecker = readinessChecker
        self.routingConfigPath = routingConfigPath
        self.codexConfigPath = codexConfigPath
        self.codexProfilePath = codexProfilePath
        self.sessionStore = sessionStore
        self.savedSetupStore = savedSetupStore
        self.roleLibraryStore = roleLibraryStore
        self.preferencesStore = preferencesStore
        // An unreadable file leaves the route as it was before the setting.
        self.allowsLongContext = (try? preferencesStore.load())?.allowsLongContext ?? true
        self.setupReader = setupReader
        self.modelDiscovery = modelDiscovery
        self.cliVersionProbe = cliVersionProbe
        self.diagnostics = diagnostics
        self.readiness = .pending(
            routingConfigPath: routingConfigPath,
            codexProfilePath: codexProfilePath
        )
        loadRecoveryState()
        loadRoleLibrary()
        profile.allowsLongContext = allowsLongContext
        let shouldRestoreSavedSetup = restoreSavedSetup ?? (
            routingConfigPath.standardizedFileURL
                == SwitchyardConfigWriter.defaultConfigURL.standardizedFileURL
                && codexConfigPath.standardizedFileURL
                    == CodexSetupReader.defaultConfigURL.standardizedFileURL
                && setupReader is CodexSetupReader
                && modelDiscovery is CodexModelDiscovery
        )
        if shouldRestoreSavedSetup { loadSavedSetup() }
        // A route this launch adopted rather than started is watched too: the
        // generated profile can be edited under it just as easily.
        if isApplied { beginWatchingCodexSelection() }
    }

    // MARK: - Navigation

    package var canGoBack: Bool { step != .provider && !isBusy }

    /// Why the Next button is disabled on this step, if it is.
    package var advanceBlocker: String? { blocker(for: step) }

    /// The same question asked about any step, so the step rail can say which
    /// steps are safe to jump to.
    package func blocker(for step: Step) -> String? {
        switch step {
        case .provider:
            guard discoveryState.isReady else { return discoveryState.blockingMessage }
            return discoveredModels.count >= 2
                ? nil : "Your Codex subscription needs at least two models to create a route."
        case .tiers:
            guard discoveryState.isReady else { return discoveryState.blockingMessage }
            if let unverifiedAssignmentBlocker { return unverifiedAssignmentBlocker }
            if profile.algorithm == nil { return "Choose a routing algorithm." }
            let missing = profile.unassignedTiers
            if !missing.isEmpty {
                return "Assign a model to "
                    + missing.map(\.displayName).formattedList()
                    + "."
            }
            return profile.roleValidationErrors.first
        case .confirm:
            return nil
        }
    }

    /// Set while the classifier target list is outside the supported range.
    package var tierCountBlocker: String? {
        guard profile.algorithm == .llmClassifier else { return nil }
        let count = profile.tiers.count
        if count < TaskTier.minimumCount {
            return "Add at least \(TaskTier.minimumCount) tiers."
        }
        if count > TaskTier.maximumCount {
            return "Remove tiers — at most \(TaskTier.maximumCount) are supported."
        }
        return nil
    }

    package var canAdvance: Bool { step != .confirm && advanceBlocker == nil && !isBusy }

    package func next() {
        guard canAdvance, let following = Step(rawValue: step.rawValue + 1) else { return }
        step = following
    }

    package func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// A finished setup is edited far more often than it is created, so every
    /// step the current one has already cleared stays directly reachable.
    package func canJump(to target: Step) -> Bool {
        guard !isBusy, target != step else { return false }
        guard target.rawValue > step.rawValue else { return true }
        return Step.allCases
            .filter { $0.rawValue >= step.rawValue && $0.rawValue < target.rawValue }
            .allSatisfy { blocker(for: $0) == nil }
    }

    package func jump(to target: Step) {
        guard canJump(to: target) else { return }
        step = target
    }

    package func reconfigure() {
        guard !isBusy, !isApplied, !processManager.status.isRunning else { return }
        step = .provider
    }

    // MARK: - Subscription discovery

    package var discoveredModels: [CodexSubscriptionModel] { discoveryState.models }

    /// The four setup rows shown on the account step.
    package var preflight: CodexPreflight {
        CodexPreflight.make(
            state: discoveryState,
            setup: codexSetup,
            cliVersion: codexCLIVersion,
            modelCount: discoveredModels.count,
            defaultModelID: discoveredModels.first(where: \.isDefault)?.id
        )
    }

    package var isDiscovering: Bool { discoveryState == .loading || discoveryState == .idle }

    /// Discovery starts its own `codex app-server` without `--profile`, so the
    /// generated layer no longer hides the account's models from it. What it
    /// still must not do is re-inventory the account underneath a live route:
    /// a model dropped from the list clears the assignment a running Switchyard
    /// config was generated from.
    package var discoveryRefreshBlocker: String? {
        guard isApplied || processManager.status.isRunning else { return nil }
        return "Routing is active — stop it before re-checking your subscription models."
    }

    package var canRefreshDiscovery: Bool { discoveryRefreshBlocker == nil && !isDiscovering }

    /// When the active route started, for the statistics window's uptime.
    package var routingStartedAt: Date? { activeSession?.startedAt }

    /// The generated Codex profile backing the active route, if one is active.
    package var installedProfilePath: String? { activeSession?.codexProfilePath.path }

    /// What the user types to start a Codex session through the active route.
    package var codexLaunchCommand: String { CodexLocations.launchCommand }

    /// A block the user can paste into their own `config.toml` by hand, for
    /// Codex Desktop and any session that does not select `--profile
    /// switchyard-desktop`. Desktop has no way to select a profile, so the generated
    /// layer above is invisible to it; this is the only path that reaches it,
    /// and it is entirely the user's own edit to their own file.
    package var manualDesktopSnippet: String { CodexProfileWriter.manualConfigSnippet(profile: profile) }

    package var discoveredModelIDs: Set<String> {
        Set(discoveredModels.map(\.id))
    }

    package var unverifiedAssignmentBlocker: String? {
        if let judge = profile.judgeModelID, !discoveredModelIDs.contains(judge) {
            return "Choose a discovered Codex model for the judge."
        }
        let unverified = profile.allTargets.filter {
            guard let modelID = $0.assignedModel else { return false }
            return !discoveredModelIDs.contains(modelID)
        }
        guard !unverified.isEmpty else { return nil }
        return "Choose a discovered Codex model for "
            + unverified.map(\.displayName).formattedList()
            + "."
    }

    /// Runs automatically on first launch. Subsequent calls are no-ops until
    /// the user explicitly asks to refresh the subscription model list.
    package func discoverSubscriptionModelsIfNeeded() async {
        guard discoveryState == .idle else { return }
        await refreshSubscriptionModels()
    }

    /// Re-reads the local setup and repeats authenticated model discovery.
    package func refreshSubscriptionModels() async {
        guard discoveryState != .loading, discoveryRefreshBlocker == nil else { return }
        discoveryState = .loading

        let setupReader = setupReader
        let modelDiscovery = modelDiscovery
        let configPath = codexConfigPath
        let cliVersionProbe = cliVersionProbe
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.discoverSubscriptionModels(
                setupReader: setupReader,
                modelDiscovery: modelDiscovery,
                configPath: configPath,
                cliVersionProbe: cliVersionProbe
            )
        }.value

        discoveryState = outcome.state
        codexSetup = outcome.setup
        codexCLIVersion = outcome.cliVersion
        discoveredAt = Date()
        guard case .ready(let models) = outcome.state else { return }
        profile.imageCapableModelIDs = Set(models.filter(\.supportsImages).map(\.id))
        // Keep the windows already known when this read failed: an unreadable
        // catalog is a reason to leave the route as it is, not to shrink it.
        if !outcome.contextWindows.isEmpty {
            discoveredContextWindows = outcome.contextWindows
            profile.modelContextWindows = outcome.contextWindows
        }
        if !outcome.supportedEfforts.isEmpty { supportedEfforts = outcome.supportedEfforts }
        clearAssignmentsNotInDiscoveredModels(models)
    }

    // MARK: - Tiers

    package var canAddTier: Bool { profile.canAddTier }
    package var canRemoveTier: Bool { profile.canRemoveTier }

    package func selectRoutingAlgorithm(_ algorithm: RoutingAlgorithm) {
        profile.selectAlgorithm(algorithm)
    }

    package func addTier() {
        profile.addTier()
    }

    package func removeTier(id: UUID) {
        profile.removeTier(id: id)
    }

    // MARK: - Roles

    package var roles: [RoutingRole] { profile.roles }
    package var targetRoles: [RoutingRole] { profile.roles.targets }
    package var classifierRole: RoutingRole? { profile.classifierRole }

    package func role(of tier: TaskTier) -> RoutingRole? { profile.role(of: tier) }

    package func assignRole(_ roleID: UUID?, to tierID: UUID) {
        profile.assignRole(roleID, to: tierID)
    }

    /// Edits a role everywhere it exists: in the library, which is where it is
    /// written, and in this setup, which holds a copy of it.
    package func updateRole(_ role: RoutingRole) {
        roleLibrary.upsert(role)
        persistRoleLibrary()
        guard profile.roles.contains(where: { $0.id == role.id }) else { return }
        profile.updateRole(role)
    }

    /// Writes a new role into the library and returns it. It reaches a setup
    /// only when a target is given it.
    @discardableResult
    package func addRole(named name: String = "New role", kind: RoutingRole.Kind = .target) -> RoutingRole {
        let role = roleLibrary.add(kind: kind, name: name)
        persistRoleLibrary()
        return role
    }

    /// Writes an edited prompt into the library as a reusable role.
    @discardableResult
    package func addRole(named name: String, prompt: String, description: String = "", tags: [String] = []) -> RoutingRole {
        var role = roleLibrary.add(kind: .target, name: name, text: description, tags: tags)
        role.systemPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
        roleLibrary.upsert(role)
        persistRoleLibrary()
        return role
    }

    /// A copy of a role under its own identity, so a shipped role can be taken
    /// as a starting point without losing the original.
    @discardableResult
    package func duplicateRole(id: UUID) -> RoutingRole? {
        let copy = roleLibrary.duplicate(id: id)
        persistRoleLibrary()
        return copy
    }

    /// Removes a role from the library and from this setup. Targets holding it
    /// keep the wording it left behind, so nothing silently loses a description.
    package func removeRole(id: UUID) {
        roleLibrary.remove(id: id)
        persistRoleLibrary()
        profile.removeRole(id: id)
    }

    /// Puts a shipped role back to the wording it was written with.
    package func resetRoleToBuiltIn(id: UUID) {
        guard let shipped = roleLibrary.resetToBuiltIn(id: id) else { return }
        persistRoleLibrary()
        guard profile.roles.contains(where: { $0.id == shipped.id }) else { return }
        profile.updateRole(shipped)
    }

    /// Makes a library role available to this setup's targets, and hands back
    /// the copy the setup now holds.
    ///
    /// A classifier role replaces the judge prompt outright: a route has one
    /// judge, and two classifier roles in a profile would leave which one runs
    /// up to ordering.
    @discardableResult
    package func useRoleInSetup(_ roleID: UUID) -> RoutingRole? {
        guard let role = roleLibrary[id: roleID] else { return nil }
        if role.kind == .classifier {
            profile.roles.removeAll { $0.kind == .classifier }
            profile.roles.insert(role, at: 0)
        } else if let index = profile.roles.firstIndex(where: { $0.id == role.id }) {
            profile.roles[index] = role
        } else {
            profile.roles.append(role)
        }
        profile.syncRolesIntoTargets()
        return role
    }

    /// Gives a target a library role, taking the role into the setup first.
    ///
    /// The picker on the routing step offers the whole library, so choosing
    /// there is the same gesture whether or not this setup has met the role
    /// before.
    package func assignLibraryRole(_ roleID: UUID, to tierID: UUID) {
        guard useRoleInSetup(roleID) != nil else { return }
        profile.assignRole(roleID, to: tierID)
    }

    /// Library roles a target can be given: the ones this setup already holds
    /// first, then the rest of the library.
    package var assignableRoles: (inSetup: [RoutingRole], library: [RoutingRole]) {
        let offered = roleLibrary.targets
        return (offered.filter { isRoleInSetup($0) }, offered.filter { !isRoleInSetup($0) })
    }

    /// Whether this setup already carries the role, so the screen can offer to
    /// add it rather than offering it twice.
    package func isRoleInSetup(_ role: RoutingRole) -> Bool {
        profile.roles.contains { $0.id == role.id }
    }

    /// Targets in this setup holding the role.
    package func targetsHolding(_ role: RoutingRole) -> [TaskTier] {
        profile.allTargets.filter { $0.roleID == role.id }
    }

    package func isRoleInUse(_ role: RoutingRole) -> Bool { profile.isRoleInUse(role) }

    // MARK: - Role library

    @discardableResult
    package func addRoleGroup() -> RoleGroup {
        let group = roleLibrary.addGroup()
        persistRoleLibrary()
        return group
    }

    package func updateRoleGroup(_ group: RoleGroup) {
        roleLibrary.updateGroup(group)
        persistRoleLibrary()
    }

    package func removeRoleGroup(id: UUID) {
        roleLibrary.removeGroup(id: id)
        for index in profile.roles.indices { profile.roles[index].groupIDs.remove(id) }
        persistRoleLibrary()
    }

    package var canLoadRoleGroupSetup: Bool {
        !isBusy && !isApplied && !processManager.status.isRunning
    }

    /// Groups holding a saved routing setup, in library order.
    ///
    /// A group is otherwise found only by opening the roles editor, choosing
    /// it from a filter menu, and opening its own settings — three steps
    /// before the one that matters. This is what a direct "load a project
    /// setup" list offers instead.
    package var groupsWithSavedSetup: [RoleGroup] {
        roleLibrary.groups.filter { $0.routingProfile != nil }
    }

    package func saveSetupToRoleGroup(id: UUID) {
        guard var group = roleLibrary.groups.first(where: { $0.id == id }) else { return }
        // Only assigned roles belong to this collection, not every unused
        // default that the profile happens to carry.
        let used = profile.roles.filter { profile.isRoleInUse($0) }
        for var role in used {
            role.groupIDs.insert(id)
            updateRole(role)
        }
        group.routingProfile = profile
        updateRoleGroup(group)
    }

    @discardableResult
    package func loadRoleGroupSetup(id: UUID) -> Bool {
        guard canLoadRoleGroupSetup,
              let saved = roleLibrary.groups.first(where: { $0.id == id })?.routingProfile else { return false }
        profile = saved
        adoptSetupRolesIntoLibrary()
        if discoveryState.isReady {
            profile.imageCapableModelIDs = Set(discoveredModels.filter(\.supportsImages).map(\.id))
            clearAssignmentsNotInDiscoveredModels(discoveredModels)
        }
        return true
    }

    /// Reads the library, falling back to the shipped one. A library that
    /// cannot be read is never overwritten silently: the error is surfaced and
    /// the shipped roles stand in until the user saves something.
    private func loadRoleLibrary() {
        do {
            if let stored = try roleLibraryStore.load() {
                roleLibrary = stored
            } else {
                roleLibrary = .shipped
            }
        } catch {
            roleLibrary = .shipped
            roleLibraryError =
                "The role library could not be read, so the built-in roles are shown instead: "
                + error.localizedDescription
        }
        adoptSetupRolesIntoLibrary()
        // The profile was built before the library was read, so it starts on
        // the shipped wording until this pass hands it the user's own.
        syncRolesFromLibrary()
    }

    /// Takes any role this setup holds that the library lacks.
    private func adoptSetupRolesIntoLibrary() {
        let before = roleLibrary.roles.count
        roleLibrary.absorb(profile.roles)
        guard roleLibrary.roles.count != before else { return }
        persistRoleLibrary()
    }

    /// Takes the library's wording for every role this setup recognises.
    private func syncRolesFromLibrary() {
        guard !isSyncingRolesFromLibrary else { return }
        var updated = profile.roles
        var changed = false
        for index in updated.indices {
            guard let written = roleLibrary[id: updated[index].id], written != updated[index] else {
                continue
            }
            updated[index] = written
            changed = true
        }
        guard changed else { return }
        isSyncingRolesFromLibrary = true
        profile.roles = updated
        profile.syncRolesIntoTargets()
        isSyncingRolesFromLibrary = false
    }

    private func persistPreferences() {
        do {
            try preferencesStore.save(AppPreferences(allowsLongContext: allowsLongContext))
            preferencesError = nil
        } catch {
            preferencesError = "The setting could not be saved: " + error.localizedDescription
        }
    }

    private func persistRoleLibrary() {
        do {
            try roleLibraryStore.save(roleLibrary)
            roleLibraryError = nil
        } catch {
            roleLibraryError = "This role could not be saved to the library: "
                + error.localizedDescription
        }
    }

    /// Effort levels the model assigned to a target holding this role does not
    /// list, so the wizard can say so before Switchyard forwards it anyway.
    package func unsupportedEffortModels(for role: RoutingRole) -> [String] {
        guard let effort = role.effort else { return [] }
        return profile.allTargets
            .filter { $0.roleID == role.id }
            .compactMap(\.assignedModel)
            .filter { model in
                guard let supported = supportedEfforts[model] else { return false }
                return !supported.contains(effort.rawValue)
            }
    }

    /// Whether the generated route will actually advertise image input.
    package var declaresImageInput: Bool {
        profile.advertisesImageInput && readiness.serverSupportsVision
    }

    /// What the generated route will tell Codex about image input, and why.
    package var imageInputSummary: String {
        if profile.advertisesImageInput {
            return readiness.serverSupportsVision
                ? "Enabled — every assigned model accepts images."
                : "Off — this switchyard-server build does not take the route `vision` key. "
                    + "Update switchyard-desktop to route images."
        }
        let textOnly = profile.textOnlyAssignedModels
        guard !textOnly.isEmpty else {
            return "Enabled once every role has a model that accepts images."
        }
        return "Off — \(textOnly.formattedList()) takes text only, so Codex would drop an "
            + "attached image."
    }

    /// Whether the route names a window at all, rather than leaving Codex on
    /// its own default.
    package var declaresContextWindow: Bool { profile.routeContextWindow != nil }

    /// What the generated route will tell Codex the conversation window is.
    ///
    /// Codex measures one window against a whole conversation and compacts at
    /// 95% of what the route names, so this is the number that decides how much
    /// history survives — and how much of each model's advertised capacity is
    /// actually reachable.
    package var contextWindowSummary: String {
        guard let window = profile.routeContextWindow else {
            return "Codex keeps its own 272k default — assign every role a discovered model "
                + "to advertise what they really accept."
        }
        let applied = Self.compactTokens(window * 95 / 100)
        if profile.longContextIsBlocked {
            return "\(Self.compactTokens(window)) — long context is off in Settings, so Codex "
                + "compacts at \(applied) and stays under OpenAI's premium rates."
        }
        let capping = profile.contextWindowCappingModels
        guard !capping.isEmpty else {
            return "\(Self.compactTokens(window)) — every assigned model's maximum. "
                + "Codex compacts at \(applied)."
        }
        return "\(Self.compactTokens(window)) — the most \(capping.formattedList()) "
            + "\(capping.count == 1 ? "accepts" : "accept"), and one window covers the whole "
            + "conversation. Codex compacts at \(applied); drop that role to raise it."
    }

    private static func compactTokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Description of the user-selected routing behavior.
    package var routingSummary: String {
        guard let algorithm = profile.algorithm else {
            return "Choose a routing algorithm to configure its model roles."
        }
        if profile.nativeRouteOptions != nil {
            return "\(algorithm.displayName) uses the native route options shown below."
        }
        if algorithm.supportsClassifyTrigger {
            return "\(algorithm.summary) Classification: \(profile.classifyTrigger.displayName.lowercased())."
        }
        return algorithm.summary
    }

    // MARK: - Apply

    package var isBusy: Bool {
        if case .working = applyState { return true }
        return false
    }

    package var isApplied: Bool {
        activeSession != nil
    }

    package var canApply: Bool {
        discoveryState.isReady
            && unverifiedAssignmentBlocker == nil
            && profile.isValid
            && !isBusy
            && !isApplied
    }

    /// Everything Start routing still needs, in the order to surface it.
    /// A leftover from an earlier run is reported separately: Start replaces the
    /// generated profile, so it is never a reason to hold Start back.
    package var startBlocker: String? {
        if isBusy { return nil }
        if isApplied { return nil }
        if !discoveryState.isReady { return discoveryState.blockingMessage }
        if let unverifiedAssignmentBlocker { return unverifiedAssignmentBlocker }
        if let invalid = profile.validationErrors.first { return invalid }
        if !readiness.isReady { return readiness.blockers.first }
        return nil
    }

    package var canStartRouting: Bool {
        canApply && readiness.isReady
    }

    /// Everything but the explicit acknowledgement is ready.
    package var awaitsSideEffectConsent: Bool {
        false
    }

    package var recoveryMessage: String? {
        switch recoveryState {
        case .none:
            return nil
        case .cleanedUp(let detail), .warning(let detail):
            return detail
        }
    }

    /// Preview shown on the review step. Empty while the profile is incomplete.
    package var configPreview: String {
        guard discoveryState.isReady,
              unverifiedAssignmentBlocker == nil,
              profile.isValid else {
            return ""
        }
        return (try? SwitchyardConfigWriter.render(
            profile: profile, serverSupportsVision: readiness.serverSupportsVision
        )) ?? ""
    }

    package var resolvedBinary: URL? {
        readiness.resolvedBinaryPath
            ?? SwitchyardBinaryLocator.locate(explicitPath: binaryPathOverride)
    }

    /// Changes whenever a prerequisite can change, so the review view can refresh safely.
    package var readinessFingerprint: String {
        var values = [
            binaryPathOverride,
            profile.algorithm?.rawValue ?? "",
            profile.classifyTrigger.rawValue,
            profile.nativeRouteOptions ?? "",
            profile.judgeModelID ?? "",
            profile.judgeNativeOptions ?? "",
            profile.reviewerSystemPrompt ?? "",
            profile.classifierTargetID?.uuidString ?? "",
            profile.defaultTargetID?.uuidString ?? "",
            profile.host,
            String(profile.port),
            profile.routeID,
            profile.upstreamBaseURL,
        ]
        values.append(profile.advertisesImageInput ? "vision" : "text-only")
        values.append(profile.advertisesReasoningSummaries ? "summaries" : "no-summaries")
        values.append(profile.allowsLongContext ? "long-context" : "standard-context")
        values.append(contentsOf: profile.allTargets.map {
            "\($0.id.uuidString):\($0.name):\($0.summary):\($0.modelID ?? ""):\($0.nativeOptions ?? "")"
        })
        return values.joined(separator: "\u{1F}")
    }

    /// Runs only non-destructive checks. It writes a temporary config for dry-run
    /// validation, never the routing config or the Codex profile.
    package func refreshReadiness() async {
        readiness = .pending(
            routingConfigPath: routingConfigPath,
            codexProfilePath: codexProfilePath
        )
        await reclaimLeftoverServers()
        readiness = await evaluateReadiness()
    }

    /// Stops servers an earlier run left holding 4100 or 4101 before judging
    /// whether those ports are free.
    ///
    /// Without this a crash costs the user their router until they find the
    /// orphans in a terminal: every later launch reports the port as in use and
    /// keeps Start disabled, with nothing on screen saying what holds it.
    private func reclaimLeftoverServers() async {
        guard !processManager.status.isRunning, !isApplied else { return }
        let report = await processManager.reclaimLeftovers(
            host: profile.host,
            port: profile.port,
            binaryPath: SwitchyardBinaryLocator.locate(explicitPath: binaryPathOverride)
        )
        leftoverNotice = report.reclaimed.isEmpty ? nil : report.reclaimed.joined(separator: "\n")
    }

    /// Write config → dry-run → start proxy → write the Codex profile.
    /// Any failure stops at that step; a proxy started earlier in the sequence is torn down.
    package func apply() async {
        guard !isBusy else { return }
        guard discoveryState.isReady else {
            applyState = .failed(discoveryState.blockingMessage)
            return
        }
        guard unverifiedAssignmentBlocker == nil else {
            applyState = .failed(unverifiedAssignmentBlocker ?? "Choose discovered Codex models.")
            return
        }
        guard profile.isValid else {
            applyState = .failed(profile.validationErrors.joined(separator: " "))
            return
        }
        guard !isApplied else {
            applyState = .failed("Revert the active route before applying another profile.")
            return
        }
        diagnostics.info("routing", "Applying a routing profile", [
            ("algorithm", profile.algorithm?.rawValue ?? "none"),
            ("tiers", String(profile.tiers.count)),
            ("host", profile.host),
            ("port", String(profile.port)),
            ("upstream", profile.upstreamBaseURL),
        ])
        applyState = .working("Checking prerequisites…")
        await reclaimLeftoverServers()
        let freshReadiness = await evaluateReadiness()
        readiness = freshReadiness
        guard freshReadiness.isReady, let binary = freshReadiness.resolvedBinaryPath else {
            diagnostics.error("routing", "Prerequisites are not met", [
                ("reason", freshReadiness.failureDescription)
            ])
            applyState = .failed(freshReadiness.failureDescription)
            return
        }

        var startedProxy = false
        do {
            applyState = .working("Writing routing configuration…")
            let configPath = try SwitchyardConfigWriter.write(
                profile: profile,
                to: routingConfigPath,
                serverSupportsVision: freshReadiness.serverSupportsVision
            )

            applyState = .working("Validating configuration…")
            try SwitchyardConfigWriter.validate(configPath: configPath, binaryPath: binary)

            applyState = .working("Starting the proxy…")
            try await processManager.start(
                configPath: configPath,
                binaryPath: binary,
                host: profile.host,
                port: profile.port,
                routingLogPath: RoutingLogReader.defaultLogURL,
                liteLLMModels: profile.managedLiteLLMModels
            )
            startedProxy = true

            applyState = .working("Writing the Codex profile…")
            let profilePath = try CodexProfileWriter.install(
                profile: profile,
                profilePath: codexProfilePath
            )
            let session = ActiveRoutingSession(
                routingConfigPath: configPath,
                codexProfilePath: profilePath,
                startedAt: Date()
            )
            activeSession = session
            recoveryState = .none
            do {
                try sessionStore.save(session)
                sessionRecordWarning = nil
            } catch let saveError {
                // Routing itself is unaffected: the profile is written and the
                // proxy is up. Only the automatic cleanup after a crash is lost,
                // and that leaves a file nothing reads without the flag.
                sessionRecordWarning = """
                    Routing is active, but switchyard-desktop could not save the record it uses to \
                    clean up after an unexpected quit. If this app disappears without stopping, \
                    delete \(profilePath.path) yourself.
                    Details: \(saveError.localizedDescription)
                    """
                diagnostics.error("routing", "Could not persist the active-route record", [
                    ("error", saveError.localizedDescription)
                ])
            }
            beginWatchingCodexSelection()

            let savedSetup = SavedRoutingSetup(
                profile: profile,
                discoveredModels: discoveredModels,
                binaryPathOverride: binaryPathOverride,
                savedAt: Date()
            )
            do {
                try savedSetupStore.save(savedSetup)
                lastSavedSetup = savedSetup
                hasSavedSetup = true
                savedSetupWarning = nil
            } catch {
                hasSavedSetup = false
                savedSetupWarning =
                    "Routing is active, but its reusable setup could not be saved: "
                    + error.localizedDescription
            }

            diagnostics.info("routing", "A routed Codex session is ready to start", [
                ("codexProfile", profilePath.path),
                ("launchCommand", CodexLocations.launchCommand),
                ("routingConfig", configPath.path),
            ])
            applyState = .applied(
                configPath: configPath.path,
                profilePath: profilePath.path
            )
        } catch {
            diagnostics.error("routing", "Applying the routing profile failed", [
                ("stage", applyState.workingMessage ?? "unknown"),
                ("error", error.localizedDescription),
                ("proxyStarted", startedProxy ? "yes" : "no"),
            ])
            if startedProxy { processManager.stop() }
            applyState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Codex profile drift

    /// How often the active route re-reads its generated profile. Only this app
    /// writes that file, so drift is rare — but the app is usually in the
    /// background when a user edits or deletes it, so the check cannot wait for
    /// a window to be opened.
    private static let codexSelectionWatchInterval = Duration.seconds(5)

    /// Re-reads the generated profile off the main actor and records any drift.
    package func refreshCodexSelection() async {
        let profilePath = codexProfilePath
        let selection = await Task.detached(priority: .utility) {
            CodexProfileWriter.readSelection(profilePath: profilePath)
        }.value
        updateCodexSelection(selection)
    }

    /// Compares a selection that was just read with the running route.
    ///
    /// Only an applied route can drift: with no profile of this app's on disk,
    /// nothing claims to route anything.
    package func updateCodexSelection(_ selection: CodexRouteSelection?) {
        guard isApplied else {
            // Assigned only on a real change: this runs on a timer, and an
            // unchanged value would invalidate every view observing it.
            if codexDrift != nil { codexDrift = nil }
            return
        }
        // A file that cannot be read at all is a missing route, not an unknown
        // one: `--profile switchyard-desktop` has nothing to resolve either way.
        // Spelled out rather than coalesced: a selection that matches the route
        // also yields nil, and the two must not collapse into one answer.
        let drift: CodexRouteDrift?
        if let selection {
            drift = selection.drift(routeID: profile.routeID)
        } else {
            drift = .profileMissing
        }
        guard drift != codexDrift else { return }
        codexDrift = drift
        guard drift != nil else { return }
        codexRepairError = nil
        diagnostics.warning("routing", "The generated Codex profile no longer matches the route", [
            ("codexProfile", codexProfilePath.path),
            ("selectedModel", selection?.model ?? "none"),
            ("selectedProvider", selection?.provider ?? "none"),
            ("routeID", profile.routeID),
        ])
    }

    /// Generates the profile again over whatever the file now holds. Nothing
    /// else on disk is read or written: the file is this app's alone.
    @discardableResult
    package func repairCodexSelection() async -> Bool {
        guard isApplied, codexDrift != nil else { return false }
        do {
            try CodexProfileWriter.install(profile: profile, profilePath: codexProfilePath)
            diagnostics.info("routing", "Wrote the Codex profile again", [
                ("codexProfile", codexProfilePath.path),
                ("routeID", profile.routeID),
            ])
            codexRepairError = nil
            await refreshCodexSelection()
            return codexDrift == nil
        } catch {
            diagnostics.error("routing", "Could not write the Codex profile", [
                ("codexProfile", codexProfilePath.path),
                ("error", error.localizedDescription),
            ])
            codexRepairError = """
                switchyard-desktop could not write \(codexProfilePath.path): \
                \(error.localizedDescription)
                """
            return false
        }
    }

    private func beginWatchingCodexSelection() {
        guard codexSelectionWatch == nil else { return }
        codexSelectionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: WizardModel.codexSelectionWatchInterval)
                guard !Task.isCancelled, let self else { return }
                await self.refreshCodexSelection()
            }
        }
    }

    private func endWatchingCodexSelection() {
        codexSelectionWatch?.cancel()
        codexSelectionWatch = nil
        codexDrift = nil
        codexRepairError = nil
    }

    /// Restores the exact captured Codex state before stopping the proxy.
    @discardableResult
    package func revert() async -> Bool {
        guard !isBusy else { return false }
        isStopping = true
        defer { isStopping = false }
        diagnostics.info("routing", "Removing the Codex profile and stopping routing")
        applyState = .working("Removing the Codex profile…")
        let profilePath = activeSession?.codexProfilePath ?? codexProfilePath

        do {
            try CodexProfileWriter.remove(profilePath: profilePath)
        } catch {
            // The proxy stays up: a profile still on disk points at it, and a
            // routed session is better served than broken while the user looks.
            let message = """
                switchyard-desktop could not remove \(profilePath.path), so routing was left running. \
                Delete that file to stop routing; your own Codex configuration beside it was \
                never changed.
                Details: \(error.localizedDescription)
                """
            recoveryState = .warning(message)
            applyState = .failed(message)
            return false
        }

        processManager.stop()
        activeSession = nil
        sessionRecordWarning = nil
        endWatchingCodexSelection()
        recoveryState = .none
        diagnostics.info("routing", "The Codex profile was removed and routing was stopped", [
            ("codexProfile", profilePath.path)
        ])
        do {
            try sessionStore.clear()
            applyState = .idle
        } catch {
            // Cleanup already completed; a stale record is ignored and removed
            // on a later launch, because no generated profile is left to match.
            applyState = .failed(
                "Routing was stopped and the Codex profile removed, but the record of it could "
                    + "not be deleted: \(error.localizedDescription)"
            )
        }
        return true
    }

    /// Tidies up for a termination this app cannot turn into a prompt: a
    /// log-out, a Force Quit, or a quit arriving while no window can host the
    /// confirmation. It removes the generated profile so a later
    /// `codex --profile switchyard-desktop` cannot reach a stopped proxy.
    ///
    /// Nothing here is load-bearing. The file is this app's own, the user's
    /// Codex configuration is untouched either way, and a termination this never
    /// sees — a crash, a kill — simply leaves the file for the next launch.
    ///
    /// Runs inside `applicationWillTerminate`, so it touches only files and the
    /// child process and shows nothing.
    package func cleanUpForTermination() {
        diagnostics.info("app", "Quitting", [
            ("routing", processManager.status.isRunning ? "active" : "stopped"),
            ("activeSession", activeSession == nil ? "none" : "cleaning up"),
        ])
        codexSelectionWatch?.cancel()
        codexSelectionWatch = nil
        if let activeSession {
            do {
                try CodexProfileWriter.remove(profilePath: activeSession.codexProfilePath)
                self.activeSession = nil
                try? sessionStore.clear()
            } catch {
                // The record stays on disk on purpose: the next launch reads it
                // and removes the file then.
                diagnostics.error("routing", "Could not remove the Codex profile while quitting", [
                    ("codexProfile", activeSession.codexProfilePath.path),
                    ("error", error.localizedDescription),
                ])
            }
        }
        processManager.stop()
    }

    /// The app delegate calls this for a normal termination request.
    /// Returning `false` means the confirmation sheet is now responsible for
    /// either reverting first or cancelling the quit.
    package func requestQuit() -> Bool {
        guard !isBusy else { return false }
        guard isApplied || processManager.status.isRunning else {
            return true
        }
        shouldConfirmQuit = true
        return false
    }

    package func cancelQuit() {
        shouldConfirmQuit = false
    }

    @discardableResult
    package func revertAndQuit() async -> Bool {
        shouldConfirmQuit = false
        return await revert()
    }

    private func evaluateReadiness() async -> RoutingReadiness {
        let checker = readinessChecker
        let profile = profile
        let binaryPathOverride = binaryPathOverride
        let routingConfigPath = routingConfigPath
        let codexProfilePath = codexProfilePath
        return await Task.detached(priority: .userInitiated) {
            checker.check(
                profile: profile,
                binaryPathOverride: binaryPathOverride,
                routingConfigPath: routingConfigPath,
                codexProfilePath: codexProfilePath
            )
        }.value
    }

    nonisolated private static func discoverSubscriptionModels(
        setupReader: any CodexSetupReading,
        modelDiscovery: any CodexModelDiscovering,
        configPath: URL,
        cliVersionProbe: @Sendable () -> String?
    ) -> DiscoveryOutcome {
        let setup: CodexSetup
        do {
            setup = try setupReader.read(configPath: configPath)
        } catch let failure as CodexSetupReader.Failure {
            return DiscoveryOutcome(state: .setupFailed(failure), setup: nil, cliVersion: nil)
        } catch {
            return DiscoveryOutcome(state: .unexpectedFailure, setup: nil, cliVersion: nil)
        }

        let cliVersion = cliVersionProbe()
        do {
            let models = try modelDiscovery.discover(using: setup)
            return DiscoveryOutcome(
                state: .ready(models),
                setup: setup,
                cliVersion: cliVersion,
                contextWindows: modelDiscovery.contextWindows(using: setup),
                supportedEfforts: modelDiscovery.supportedEfforts(using: setup)
            )
        } catch let failure as CodexModelDiscovery.Failure {
            return DiscoveryOutcome(
                state: .discoveryFailed(failure), setup: setup, cliVersion: cliVersion
            )
        } catch {
            return DiscoveryOutcome(state: .unexpectedFailure, setup: setup, cliVersion: cliVersion)
        }
    }

    private func clearAssignmentsNotInDiscoveredModels(_ models: [CodexSubscriptionModel]) {
        let availableIDs = Set(models.map(\.id))
        for index in profile.tiers.indices {
            guard let assignedModel = profile.tiers[index].assignedModel,
                  !availableIDs.contains(assignedModel) else {
                continue
            }
            profile.tiers[index].modelID = nil
        }
    }

    /// Deals with whatever a run that never cleaned up left behind.
    ///
    /// Two shapes are possible. This version's own record names a generated
    /// profile that only has to be deleted. A record from a version that patched
    /// `config.toml` names a file that belongs to the user, and putting it back
    /// is the last thing this app ever does to it.
    private func loadRecoveryState() {
        let session: ActiveRoutingSession?
        do {
            session = try sessionStore.load()
        } catch {
            // Not the current shape. A record an older version wrote is worth
            // acting on; anything else is a file this app cannot use.
            if let legacy = sessionStore.loadLegacyPatchedConfig() {
                undoLegacyPatchedConfig(legacy)
            } else {
                diagnostics.error("routing", "Could not read the active-route record", [
                    ("error", error.localizedDescription)
                ])
                recoveryState = .warning(
                    """
                    switchyard-desktop could not read \(ActiveRoutingSessionStore.defaultURL.path), so \
                    it does not know whether an earlier run left a Codex profile behind. Starting \
                    routing writes a fresh one either way.
                    Details: \(error.localizedDescription)
                    """
                )
            }
            return
        }
        guard let session else { return }
        activeSession = session

        diagnostics.warning("routing", "Found a routing session left by an earlier run", [
            ("startedAt", DiagnosticLog.timestamp(session.startedAt)),
            ("codexProfile", session.codexProfilePath.path),
            ("profileStillInstalled", session.requiresCleanUp() ? "yes" : "no"),
        ])
        guard session.requiresCleanUp() else {
            // Nothing of this app's is left on disk, so neither is the record.
            try? sessionStore.clear()
            activeSession = nil
            return
        }
        // The proxy from that run is gone. The profile is harmless where it is —
        // no session reads it without the flag — but it would point the next
        // routed session at a dead port, so remove it now.
        removeAbandonedProfile(session)
    }

    /// Deletes a generated profile an earlier run left behind, reporting what
    /// happened either way. Never blocks Start: it replaces the file regardless.
    private func removeAbandonedProfile(_ session: ActiveRoutingSession) {
        do {
            try CodexProfileWriter.remove(profilePath: session.codexProfilePath)
            activeSession = nil
            try? sessionStore.clear()
            diagnostics.info("routing", "Removed the Codex profile left by an earlier run", [
                ("codexProfile", session.codexProfilePath.path)
            ])
            recoveryState = .cleanedUp(
                """
                switchyard-desktop did not shut down cleanly last time. The Codex profile it had \
                written has now been removed, so `\(CodexLocations.launchCommand)` no longer \
                points at a proxy that is not running. Your own Codex configuration was never \
                changed. Start routing whenever you want it back.
                Removed: \(session.codexProfilePath.path)
                """
            )
        } catch {
            diagnostics.error("routing", "Could not remove the profile left by an earlier run", [
                ("codexProfile", session.codexProfilePath.path),
                ("error", error.localizedDescription),
            ])
            recoveryState = .warning(
                """
                An earlier run left \(session.codexProfilePath.path) behind and switchyard-desktop \
                could not remove it. Until it goes, a session started with \
                `\(CodexLocations.launchCommand)` reaches a proxy that is not running — every \
                other Codex session is unaffected. Starting routing here replaces the file.
                Details: \(error.localizedDescription)
                """
            )
        }
    }

    /// Restores a `config.toml` an older version of this app had patched.
    /// Runs once, at the first launch after the upgrade.
    private func undoLegacyPatchedConfig(_ legacy: LegacyPatchedConfigSession) {
        diagnostics.warning("routing", "Found a record from a version that patched config.toml", [
            ("codexConfig", legacy.codexCapture.configPath.path),
            ("backup", legacy.codexCapture.backupPath?.path ?? "none"),
        ])
        switch LegacyCodexConfigRestore.run(legacy) {
        case .restored(let detail):
            try? sessionStore.clear()
            recoveryState = .cleanedUp(detail)
        case .nothingToRestore:
            try? sessionStore.clear()
        case .failed(let detail):
            recoveryState = .warning(detail)
        }
    }

    private func loadSavedSetup() {
        do {
            let savedSetup: SavedRoutingSetup
            if let stored = try savedSetupStore.load() {
                savedSetup = stored
            } else if FileManager.default.fileExists(atPath: routingConfigPath.path) {
                savedSetup = try SavedRoutingSetup.migrateGeneratedConfig(from: routingConfigPath)
                try savedSetupStore.save(savedSetup)
            } else {
                return
            }
            guard savedSetup.isUsable else {
                try savedSetupStore.clear()
                savedSetupWarning = "The saved routing setup is no longer valid. Configure it again."
                return
            }
            profile = savedSetup.profile
            // A setup written before the library existed carries wording the
            // library has never seen. Take it in rather than leaving the user
            // with roles they can use but cannot find.
            adoptSetupRolesIntoLibrary()
            lastSavedSetup = savedSetup
            binaryPathOverride = savedSetup.binaryPathOverride
            // Discovery stays pending so the launch pass re-checks these
            // assignments against the live subscription. Adopting the saved
            // snapshot as the discovered list would compare the setup against
            // itself, and a model dropped from the account would stay assigned.
            hasSavedSetup = true
            step = .confirm
        } catch {
            try? savedSetupStore.clear()
            savedSetupWarning =
                "The saved routing setup could not be read. Configure it again: "
                + error.localizedDescription
        }
    }
}

package extension Array where Element == String {
    /// "a", "a and b", "a, b and c" — for naming the tiers a blocker calls out.
    package func formattedList() -> String {
        switch count {
        case 0: return ""
        case 1: return self[0]
        default: return dropLast().joined(separator: ", ") + " and " + self[count - 1]
        }
    }
}
