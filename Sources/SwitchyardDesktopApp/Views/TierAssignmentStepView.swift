import SwitchyardDesktopKit
import SwiftUI

/// Step 2 — pick how a request is routed on the left, then fill in the targets
/// that algorithm defines on the right. Only discovered subscription models can
/// be assigned, and everything Switchyard decides per request is grouped into
/// one panel instead of being spread across the page.
struct TierAssignmentStepView: View {
    @Bindable var model: WizardModel
    @State private var showNativeOptions = false
    @State private var showRoles = false
    @State private var showJudgePrompt = false
    @State private var showAccountModels = false
    @State private var showAllAlgorithms = false

    /// The routes worth comparing first. The rest are real Switchyard routes
    /// that most setups never need, so they stay one click away.
    static let commonAlgorithms: [RoutingAlgorithm] = [
        .auto, .stageRouter, .capability, .llmClassifier, .advisor, .planExecute
    ]
    static let rareAlgorithms: [RoutingAlgorithm] = RoutingAlgorithm.allCases.filter {
        !commonAlgorithms.contains($0)
    }

    private func algorithmOption(_ algorithm: RoutingAlgorithm) -> some View {
        AlgorithmOption(
            algorithm: algorithm,
            isSelected: model.profile.algorithm == algorithm
        ) {
            model.selectRoutingAlgorithm(algorithm)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "Choose routing roles",
                subtitle: """
                    Select how Switchyard should route a request, then assign only models \
                    available through your Codex subscription.
                    """
            )
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 0) {
                leftColumn
                    .frame(width: 292, alignment: .topLeading)
                Rectangle()
                    .fill(RouterTheme.line)
                    .frame(width: 1)
                rightColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            if let algorithm = model.profile.algorithm, Self.rareAlgorithms.contains(algorithm) {
                showAllAlgorithms = true
            }
        }
    }

    // MARK: - Left: algorithm and discovery

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !model.groupsWithSavedSetup.isEmpty { savedProjectSetupsPanel }

                SectionLabel("Routing algorithm")
                VStack(spacing: 8) {
                    ForEach(Self.commonAlgorithms) { algorithm in
                        algorithmOption(algorithm)
                    }
                }

                RouterDisclosurePanel(
                    title: "More algorithms",
                    subtitle: "· \(Self.rareAlgorithms.count)",
                    isExpanded: $showAllAlgorithms
                ) {
                    VStack(spacing: 8) {
                        ForEach(Self.rareAlgorithms) { algorithm in
                            algorithmOption(algorithm)
                        }
                    }
                    .padding(10)
                }

                RouterDisclosurePanel(
                    title: "Account models",
                    subtitle: "· \(model.discoveredModels.count) found",
                    isExpanded: $showAccountModels
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.discoveredModels, id: \.id) { entry in
                            HStack(spacing: 7) {
                                Text(entry.id)
                                    .font(RouterTheme.mono(11))
                                    .foregroundStyle(RouterTheme.ink2)
                                Spacer(minLength: 4)
                                if entry.isDefault {
                                    RouterTag(text: "codex default")
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Button {
                                Task { await model.refreshSubscriptionModels() }
                            } label: {
                                Label("Refresh discovery", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.routerSmall)
                            .disabled(!model.canRefreshDiscovery)
                            .help(model.discoveryRefreshBlocker ?? "Ask Codex for its model list again")
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 2)
                        Text("from \(model.codexConfigPath.path)")
                            .font(RouterTheme.mono(10))
                            .foregroundStyle(RouterTheme.ink3)
                    }
                    .padding(12)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, 4)
        }
    }

    /// A saved project setup used to take three clicks past this screen to
    /// even find — the roles sheet, its group filter, then that group's own
    /// settings — before the one click that actually loads it. Surfacing it
    /// here, first, on the screen it belongs to, is that one click.
    private var savedProjectSetupsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Project setups", trailing: "· \(model.groupsWithSavedSetup.count) saved")
            RouterPanel {
                VStack(spacing: 0) {
                    ForEach(Array(model.groupsWithSavedSetup.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { RouterDivider() }
                        savedProjectSetupRow(group)
                    }
                }
            }
            if !model.canLoadRoleGroupSetup {
                Text("Stop routing before loading another setup.")
                    .font(RouterTheme.sans(11))
                    .foregroundStyle(RouterTheme.warn)
            }
        }
    }

    private func savedProjectSetupRow(_ group: RoleGroup) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(RouterTheme.sans(12.5, .medium))
                    .foregroundStyle(RouterTheme.ink)
                Text(savedSetupSummary(group))
                    .font(RouterTheme.mono(10.5))
                    .foregroundStyle(RouterTheme.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Load") {
                model.loadRoleGroupSetup(id: group.id)
            }
            .buttonStyle(.routerSmall)
            .disabled(!model.canLoadRoleGroupSetup)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func savedSetupSummary(_ group: RoleGroup) -> String {
        let profile = group.routingProfile
        let algorithm = profile?.algorithm?.displayName ?? "Draft"
        let targets = profile.map { "\($0.tiers.count) targets" } ?? "no targets"
        guard let path = group.projectPath, !path.isEmpty else { return "\(algorithm) · \(targets)" }
        return "\(path) · \(algorithm) · \(targets)"
    }

    // MARK: - Right: the selected algorithm's roles

    @ViewBuilder
    private var rightColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let algorithm = model.profile.algorithm {
                    if algorithm.hasVariableTargets { rolesPanel }
                    targetsSection(algorithm)
                    if needsDecisionPanel(algorithm) { decisionsPanel(algorithm) }
                    nativeOptionsPanel
                    if let duplicate = duplicateModelWarning {
                        RouterNote(
                            systemImage: "exclamationmark.triangle",
                            text: duplicate,
                            tint: RouterTheme.warn
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "Choose an algorithm",
                        systemImage: "arrow.triangle.branch",
                        description: Text("Role assignments appear after you select a routing strategy.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, 4)
        }
    }

    private func targetsSection(_ algorithm: RoutingAlgorithm) -> some View {
        let editable = algorithm.hasVariableTargets
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(
                editable ? "Targets" : "\(algorithm.displayName) roles",
                trailing: editable ? "· \(model.profile.tiers.count) of \(TaskTier.maximumCount)" : nil
            )
            Text(behavior(of: algorithm))
                .font(RouterTheme.sans(11.5))
                .foregroundStyle(RouterTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            if editable {
                Text("Each target picks a role above — the work it takes and how hard its model "
                    + "thinks — then the model that serves it.")
                    .font(RouterTheme.sans(11))
                    .foregroundStyle(RouterTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(Array(model.profile.tiers.enumerated()), id: \.element.id) { index, role in
                    RoleRow(model: model, index: index, role: role, editable: editable)
                }
            }

            if editable {
                HStack(spacing: 10) {
                    Button {
                        model.addTier()
                    } label: {
                        Label("Add target", systemImage: "plus")
                    }
                    .buttonStyle(.routerGhost)
                    .disabled(!model.canAddTier)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// What the server actually does with these targets, in one paragraph.
    private func behavior(of algorithm: RoutingAlgorithm) -> String {
        switch algorithm {
        case .stageRouter:
            """
            Switchyard scores tool results on every request. Confident error or exploration signals \
            select Capable; progress can return to Efficient. Ambiguous signals use the fallback \
            target or the optional classifier. The preset matches Switchyard's efficient_first, \
            confidence_threshold = 0.5 and a three-result window.
            """
        case .llmClassifier:
            """
            Custom mode sends your target descriptions to the judge. The server validates its JSON \
            verdict and applies target_selector with the configured fallback groups. Use Capability \
            classifier for Switchyard's built-in capability prompt.
            """
        default:
            algorithm.summary
        }
    }

    private func needsDecisionPanel(_ algorithm: RoutingAlgorithm) -> Bool {
        algorithm == .llmClassifier || algorithm.requiresJudge || algorithm.supportsClassifyTrigger
    }

    /// Everything Switchyard decides per request, asked as the questions a
    /// person actually has: which model decides, who serves a turn it cannot
    /// place, and how often it is asked.
    ///
    /// The server's own vocabulary — classifier target, default target, judge
    /// model — described three controls that together answer one question, and
    /// the one control that gives the judge a model of its own sat below the two
    /// that did not. They are one picker now.
    private func decisionsPanel(_ algorithm: RoutingAlgorithm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Routing decisions")
            RouterPanel {
                VStack(alignment: .leading, spacing: 14) {
                    if algorithm.requiresJudge { judgeField(algorithm) }
                    if algorithm == .llmClassifier { fallbackField }
                    if algorithm.supportsClassifyTrigger { classifyTriggerPicker }
                    if algorithm.requiresJudge, model.profile.judgeTargetName != nil {
                        nativeOptionsEditor(
                            label: "Judge target options",
                            text: Binding(
                                get: { model.profile.judgeNativeOptions ?? "" },
                                set: { model.profile.judgeNativeOptions = $0.isEmpty ? nil : $0 }
                            ),
                            minHeight: 80
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    /// One picker for the whole question of who judges: share the model a
    /// target already has, or give the judge one of its own.
    private func judgeField(_ algorithm: RoutingAlgorithm) -> some View {
        let isAdvisor = algorithm == .advisor
        let unset = model.profile.classifierModel == nil
        return VStack(alignment: .leading, spacing: 5) {
            fieldLabel(isAdvisor ? "Which model reviews the work" : "Which model decides the routing")
            RouterMenu(
                value: judgeSelectionLabel,
                placeholder: unset,
                tint: unset ? RouterTheme.warn : nil
            ) {
                Section("Share a target's model") {
                    ForEach(model.profile.tiers) { tier in
                        Button(judgeTargetOption(tier)) {
                            model.profile.classifierTargetID = tier.id
                            model.profile.judgeModelID = nil
                        }
                    }
                }
                Section("Give it a model of its own") {
                    ForEach(model.discoveredModels, id: \.id) { entry in
                        Button(entry.displayName ?? entry.id) {
                            model.profile.judgeModelID = entry.id
                        }
                    }
                }
            }
            Text(judgeExplanation(isAdvisor: isAdvisor))
                .font(RouterTheme.sans(10.5))
                .foregroundStyle(unset ? RouterTheme.warn : RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fallbackField: some View {
        let unset = model.profile.defaultTargetID == nil
        return VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Which target serves a turn it cannot place")
            RouterMenu(
                value: targetName(model.profile.defaultTargetID),
                placeholder: unset,
                tint: unset ? RouterTheme.warn : nil
            ) {
                ForEach(model.profile.tiers) { tier in
                    Button(judgeTargetOption(tier)) { model.profile.defaultTargetID = tier.id }
                }
            }
            Text("""
                Used when the judge's answer names no target this route has — an unreadable reply, \
                or a target removed since. Every such turn goes here, so it is worth being the \
                target you would rather over-use.
                """)
                .font(RouterTheme.sans(10.5))
                .foregroundStyle(unset ? RouterTheme.warn : RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A target as the judge pickers name it: the role, and the model it serves
    /// on, since sharing a target is really sharing its model.
    private func judgeTargetOption(_ tier: TaskTier) -> String {
        guard let assigned = tier.assignedModel else { return "\(tier.displayName) · no model yet" }
        let entry = model.discoveredModels.first { $0.id == assigned }
        return "\(tier.displayName) · \(entry?.displayName ?? assigned)"
    }

    private var judgeSelectionLabel: String {
        if let judge = model.profile.judgeModelID {
            let entry = model.discoveredModels.first { $0.id == judge }
            return "\(entry?.displayName ?? judge) · a model of its own"
        }
        if let shared = model.profile.tiers.first(where: { $0.id == model.profile.classifierTargetID }) {
            return judgeTargetOption(shared)
        }
        return "Choose the model that decides…"
    }

    private func judgeExplanation(isAdvisor: Bool) -> String {
        let work = isAdvisor ? "review" : "routing call"
        if model.profile.judgeModelID != nil {
            return "The \(work) runs on a model of its own, so it never queues behind the model "
                + "serving the turn. It is a second call, billed like any other."
        }
        if let shared = model.profile.tiers.first(where: { $0.id == model.profile.classifierTargetID }) {
            return "The \(work) reuses \(shared.displayName)'s model, so this route starts nothing "
                + "extra. Give it a model of its own to keep the call off a model that serves turns."
        }
        return isAdvisor
            ? "Nothing reviews the work yet. Pick a target's model to reuse, or a model of its own."
            : "Nothing decides the routing yet, so the route cannot start. Pick a target's model to "
                + "reuse, or a model of its own."
    }

    private var separateJudgePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Separate judge model")
            RouterMenu(value: judgeModelLabel, placeholder: model.profile.judgeModelID == nil) {
                Button("Use the selected target above") { model.profile.judgeModelID = nil }
                ForEach(model.discoveredModels, id: \.id) { entry in
                    Button(entry.displayName ?? entry.id) { model.profile.judgeModelID = entry.id }
                }
            }
            Text("A judge on its own model keeps the routing call off the model that serves the turn.")
                .font(RouterTheme.sans(10.5))
                .foregroundStyle(RouterTheme.ink3)
            if model.profile.judgeTargetName != nil {
                nativeOptionsEditor(
                    label: "Judge target options",
                    text: Binding(
                        get: { model.profile.judgeNativeOptions ?? "" },
                        set: { model.profile.judgeNativeOptions = $0.isEmpty ? nil : $0 }
                    ),
                    minHeight: 80
                )
            }
        }
    }

    private var judgeModelLabel: String {
        guard let judge = model.profile.judgeModelID else { return "Use the selected target above" }
        let entry = model.discoveredModels.first { $0.id == judge }
        return entry?.displayName ?? judge
    }

    private var classifyTriggerPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("When to classify")
            RouterMenu(value: model.profile.classifyTrigger.displayName) {
                ForEach(ClassifyTrigger.allCases.filter {
                    model.profile.algorithm != .composite || $0 != .everyRequest
                }) { trigger in
                    Button(trigger.displayName) { model.profile.classifyTrigger = trigger }
                }
            }
            .disabled(model.profile.nativeRouteOptions != nil)
            Text("Holding a choice requires a session identity. Stage signals in Composite still run on every request.")
                .font(RouterTheme.sans(10.5))
                .foregroundStyle(RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Native Switchyard options

    /// The roles bar, plus the judge's own prompt underneath it where a judge
    /// runs on one: the prompt is what decides every turn, so it is readable on
    /// the step that configures it rather than only inside the library.
    private var rolesPanel: some View {
        VStack(spacing: 0) {
            rolesBar
            if model.profile.algorithm == .llmClassifier, let classifier = model.classifierRole {
                RouterDivider()
                judgePromptRow(classifier)
            }
        }
        .background(RouterTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RouterTheme.line))
        .sheet(isPresented: $showRoles) { RolesEditorView(model: model) }
    }

    /// What the judge is actually sent, group list and all.
    @ViewBuilder
    private func judgePromptRow(_ classifier: RoutingRole) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showJudgePrompt.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showJudgePrompt ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(RouterTheme.ink3)
                    Text("Judge prompt")
                        .font(RouterTheme.sans(12, .medium))
                        .foregroundStyle(RouterTheme.ink2)
                    Text("· \(classifier.displayName) role")
                        .font(RouterTheme.mono(11))
                        .foregroundStyle(RouterTheme.ink3)
                    if let effort = classifier.effort { RouterFlag(text: effort.rawValue) }
                    Spacer(minLength: 0)
                    Text(showJudgePrompt ? "Hide" : "Read")
                        .font(RouterTheme.sans(11))
                        .foregroundStyle(RouterTheme.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Judge prompt")

            if showJudgePrompt {
                if model.profile.nativeRouteOptions == nil {
                    Text("""
                        Sent to the judge on every classification. The group list is built from the \
                        targets below, so it always names the targets this route really has; the \
                        wording around it is the Classifier role, edited in the library.
                        """)
                        .font(RouterTheme.sans(10.5))
                        .foregroundStyle(RouterTheme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    ReadablePrompt(text: SwitchyardConfigWriter.judgePromptPreview(profile: model.profile))
                } else {
                    Text("""
                        Native route options own the whole algorithm body, including the judge's \
                        prompt. The Classifier role below is not what runs while they are set.
                        """)
                        .font(RouterTheme.sans(10.5))
                        .foregroundStyle(RouterTheme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    ReadablePrompt(text: classifier.text)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// A summary row that opens the role library. The step has room for a
    /// picker; a role is a paragraph of prose plus the prompt its model gets.
    private var rolesBar: some View {
        Button {
            showRoles = true
        } label: {
            HStack(spacing: 8) {
                Text("Roles")
                    .font(RouterTheme.sans(12.5, .medium))
                    .foregroundStyle(RouterTheme.ink)
                Text("· \(model.targetRoles.count) in this setup, \(model.roleLibrary.targets.count) in the library")
                    .font(RouterTheme.mono(11))
                    .foregroundStyle(RouterTheme.ink3)
                Spacer(minLength: 0)
                if let unfinished = unfinishedRoleSummary {
                    Text(unfinished)
                        .font(RouterTheme.sans(11))
                        .foregroundStyle(RouterTheme.warn)
                }
                Text("Edit")
                    .font(RouterTheme.sans(11.5))
                    .foregroundStyle(RouterTheme.ink2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RouterTheme.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What is unfinished about the roles, so the bar says it without being opened.
    private var unfinishedRoleSummary: String? {
        if let classifier = model.classifierRole, !classifier.rendersTargets {
            return "judge prompt is missing \(RoutingRole.targetsPlaceholder)"
        }
        let blank = model.targetRoles.filter { !$0.isDescribed && model.isRoleInUse($0) }
        guard !blank.isEmpty else { return nil }
        return "\(blank.map(\.displayName).formattedList()) has no description"
    }

    private var nativeOptionsPanel: some View {
        RouterDisclosurePanel(
            title: "Native Switchyard options",
            subtitle: model.profile.nativeRouteOptions == nil ? "· preset" : "· edited",
            isExpanded: $showNativeOptions
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("""
                    Edit the complete algorithm body under [routes.main] using the target keys below. \
                    Switchyard validates every field before startup. Built-in prompts apply when \
                    prompt is omitted; target descriptions are only used by Custom classifier.
                    """)
                    .font(RouterTheme.sans(11))
                    .foregroundStyle(RouterTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(zip(model.profile.allTargets, model.profile.allTargetNames)
                    .map { "\($0.1) → \($0.0.assignedModel ?? "unassigned")" }.joined(separator: "\n"))
                    .font(RouterTheme.mono(10.5))
                    .foregroundStyle(RouterTheme.ink3)
                    .textSelection(.enabled)

                if let judge = model.profile.judgeTargetName {
                    Text("Judge-only target: \(judge)")
                        .font(RouterTheme.mono(10.5))
                        .foregroundStyle(RouterTheme.ink3)
                }

                ForEach($model.profile.additionalTargets) { $target in
                    additionalTarget($target)
                }

                Button("Add target for native model groups or subagents") {
                    model.profile.additionalTargets.append(TaskTier.newTier(among: model.profile.allTargets))
                }
                .buttonStyle(.routerSmall)

                if model.profile.algorithm == .stageRouter || model.profile.algorithm == .passthrough {
                    targetField(
                        label: "Optional judge target",
                        why: "Select before editing options to use a classifier or subagent judge.",
                        selection: classifierTargetBinding
                    )
                    separateJudgePicker
                }

                if model.profile.nativeRouteOptions == nil {
                    Button("Edit native options") {
                        model.profile.nativeRouteOptions = "tool_calling = true\nreasoning = true\n"
                            + (model.declaresImageInput ? "vision = true\n" : "")
                            + SwitchyardConfigWriter.defaultRouteOptions(profile: model.profile)
                    }
                    .buttonStyle(.router)
                } else {
                    nativeOptionsEditor(
                        label: "[routes.main]",
                        text: Binding(
                            get: { model.profile.nativeRouteOptions ?? "" },
                            set: { model.profile.nativeRouteOptions = $0 }
                        ),
                        minHeight: 260
                    )
                    Button("Restore native preset") { model.profile.nativeRouteOptions = nil }
                        .buttonStyle(.routerSmall)
                }
            }
            .padding(12)
        }
    }

    private func additionalTarget(_ target: Binding<TaskTier>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Target name", text: target.name)
                    .textFieldStyle(.roundedBorder)
                    .font(RouterTheme.mono(11))
                    .frame(width: 150)
                RouterMenu(
                    value: target.wrappedValue.modelID ?? "Choose a model…",
                    placeholder: target.wrappedValue.modelID == nil
                ) {
                    ForEach(model.discoveredModels, id: \.id) { entry in
                        Button(entry.displayName ?? entry.id) { target.wrappedValue.modelID = entry.id }
                    }
                }
                Button("Remove") {
                    model.profile.additionalTargets.removeAll { $0.id == target.wrappedValue.id }
                }
                .buttonStyle(.routerSmall)
            }
            nativeOptionsEditor(
                label: "Target options",
                text: Binding(
                    get: { target.wrappedValue.nativeOptions ?? "" },
                    set: { target.wrappedValue.nativeOptions = $0.isEmpty ? nil : $0 }
                ),
                minHeight: 70
            )
        }
        .padding(10)
        .background(RouterTheme.panel2, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RouterTheme.line))
    }

    // MARK: - Shared fields

    private func targetField(
        label: String,
        why: String,
        selection: Binding<UUID?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            RouterMenu(value: targetName(selection.wrappedValue), placeholder: selection.wrappedValue == nil) {
                Button("Choose a target…") { selection.wrappedValue = nil }
                ForEach(model.profile.tiers) { role in
                    Button(role.displayName) { selection.wrappedValue = role.id }
                }
            }
            Text(why)
                .font(RouterTheme.sans(10.5))
                .foregroundStyle(RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func targetName(_ id: UUID?) -> String {
        guard let id, let role = model.profile.tiers.first(where: { $0.id == id }) else {
            return "Choose a target…"
        }
        return role.displayName
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(RouterTheme.mono(10, .medium))
            .tracking(0.6)
            .foregroundStyle(RouterTheme.ink3)
    }

    // MARK: - Bindings

    private var classifierTargetBinding: Binding<UUID?> {
        Binding(
            get: { model.profile.classifierTargetID },
            set: { model.profile.classifierTargetID = $0 }
        )
    }

    private var defaultTargetBinding: Binding<UUID?> {
        Binding(
            get: { model.profile.defaultTargetID },
            set: { model.profile.defaultTargetID = $0 }
        )
    }

    /// Two roles pointing at the same model means the router cannot change model.
    private var duplicateModelWarning: String? {
        let assigned = model.profile.tiers.compactMap(\.assignedModel)
        guard assigned.count == model.profile.tiers.count else { return nil }
        guard Set(assigned).count < assigned.count else { return nil }
        return "Some roles use the same model, so routing between them changes nothing."
    }
}

/// A labelled TOML editor, drawn like the rest of the app rather than like a
/// bare text view.
private func nativeOptionsEditor(label: String, text: Binding<String>, minHeight: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label)
            .font(RouterTheme.mono(10, .medium))
            .tracking(0.6)
            .foregroundStyle(RouterTheme.ink3)
        TextEditor(text: text)
            .font(RouterTheme.mono(11))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(RouterTheme.sunk, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(RouterTheme.line))
            .accessibilityLabel(label)
    }
}

// MARK: - Algorithm option

private struct AlgorithmOption: View {
    let algorithm: RoutingAlgorithm
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? RouterTheme.accent : RouterTheme.ink3, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                    if isSelected {
                        Circle()
                            .fill(RouterTheme.accent)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(algorithm.displayName)
                        .font(RouterTheme.sans(13, .semibold))
                        .foregroundStyle(RouterTheme.ink)
                    Text(algorithm.summary)
                        .font(RouterTheme.sans(11.5))
                        .foregroundStyle(RouterTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    costTag
                        .padding(.top, 5)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? RouterTheme.accent.opacity(0.09) : RouterTheme.panel,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? RouterTheme.accent.opacity(0.45) : RouterTheme.line,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(algorithm.displayName)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The per-turn cost difference is the reason to pick one over the other.
    private var costTag: some View {
        let paid = algorithm.requiresJudge
        return Text(paid ? "includes model evaluation" : "no judge in preset")
            .font(RouterTheme.mono(9.5))
            .tracking(0.5)
            .foregroundStyle(paid ? RouterTheme.warn : RouterTheme.ink3)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        paid ? RouterTheme.warn.opacity(0.4) : RouterTheme.line2,
                        lineWidth: 1
                    )
            )
    }
}

/// A prompt shown to be read: selectable, scrolled rather than truncated, and
/// never editable here. The wording belongs to the role, which is edited in the
/// library; this is the copy that tells you what the model is actually sent.
private struct ReadablePrompt: View {
    let text: String
    var maxHeight: CGFloat = 220

    var body: some View {
        ScrollView {
            Text(text)
                .font(RouterTheme.mono(11))
                .foregroundStyle(RouterTheme.ink2)
                .textSelection(.enabled)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: maxHeight)
        .background(RouterTheme.sunk, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(RouterTheme.line))
    }
}

// MARK: - Role row

private struct RoleRow: View {
    @Bindable var model: WizardModel
    let index: Int
    let role: TaskTier
    let editable: Bool
    @State private var showSettings = false
    @State private var showPrompt = false
    /// The role the library sheet opens on, when it is opened from this row.
    @State private var editRoleInLibrary: RoleSelection?

    /// A role id the sheet can be presented by.
    private struct RoleSelection: Identifiable { let id: UUID }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(RouterTheme.mono(10.5))
                    .foregroundStyle(RouterTheme.ink3)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if editable {
                            RouterMenu(
                                value: assignedRole?.displayName ?? "Own wording",
                                placeholder: assignedRole == nil
                            ) {
                                let offered = model.assignableRoles
                                ForEach(offered.inSetup) { option in
                                    Button(option.displayName) {
                                        model.assignRole(option.id, to: role.id)
                                    }
                                }
                                if !offered.library.isEmpty {
                                    Divider()
                                    Menu("From the library") {
                                        ForEach(offered.library) { option in
                                            Button(option.displayName) {
                                                model.assignLibraryRole(option.id, to: role.id)
                                            }
                                        }
                                    }
                                }
                                Divider()
                                Button("Own wording") { model.assignRole(nil, to: role.id) }
                            }
                            .frame(width: 168)
                            .help("The work this target takes, and how hard its model thinks")
                        } else {
                            Text(role.displayName)
                                .font(RouterTheme.sans(12.5, .medium))
                                .foregroundStyle(RouterTheme.ink)
                        }
                        if let effort = assignedRole?.effort { RouterFlag(text: effort.rawValue) }
                        if isClassifier { RouterFlag(text: "judge") }
                        if isFallback { RouterFlag(text: "fallback", tint: RouterTheme.p95) }
                    }

                    if editable, assignedRole == nil {
                        TextField("What kind of work belongs here?", text: summaryBinding)
                            .textFieldStyle(.plain)
                            .font(RouterTheme.sans(11))
                            .foregroundStyle(RouterTheme.ink3)
                    } else {
                        Text(role.summary)
                            .font(RouterTheme.sans(11))
                            .foregroundStyle(RouterTheme.ink3)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RouterMenu(
                    value: assignedLabel,
                    placeholder: role.assignedModel == nil,
                    tint: role.assignedModel == nil ? RouterTheme.warn : nil
                ) {
                    ForEach(model.discoveredModels, id: \.id) { entry in
                        Button(label(for: entry)) { modelBinding.wrappedValue = entry.id }
                    }
                }
                .frame(width: 232)
                .help(role.assignedModel ?? "Assign one of your account models")

                if editable {
                    Button {
                        model.removeTier(id: role.id)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RouterTheme.ink3)
                    .disabled(!model.canRemoveTier)
                    .help("Remove target")
                }
            }

            HStack(spacing: 8) {
                Button {
                    showSettings.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showSettings ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(hasSettings ? "Target settings · edited" : "Target settings")
                            .font(RouterTheme.sans(11))
                    }
                    .foregroundStyle(RouterTheme.ink3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    showPrompt.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showPrompt ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(promptDisclosureTitle)
                            .font(RouterTheme.sans(11))
                    }
                    .foregroundStyle(RouterTheme.ink3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(assignedRole == nil)
                Spacer(minLength: 0)
                if role.assignedModel == nil {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                        Text("Needs a model before routing can start")
                            .font(RouterTheme.sans(10.5))
                    }
                    .foregroundStyle(RouterTheme.warn)
                }
            }
            .padding(.leading, 28)

            if showSettings {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Native fields: system_prompt, reasoning_effort, extra_body. Omit id and llm_client. These settings reach Switchyard unchanged.")
                        .font(RouterTheme.sans(10.5))
                        .foregroundStyle(RouterTheme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: optionsBinding)
                        .font(RouterTheme.mono(11))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .padding(8)
                        .frame(minHeight: 90)
                        .background(RouterTheme.sunk, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(RouterTheme.line))
                        .accessibilityLabel("\(role.displayName) target settings")
                }
                .padding(.leading, 28)
            }

            if showPrompt, let assignedRole {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DESCRIPTION · READ BY THE JUDGE")
                        .font(RouterTheme.mono(9, .medium))
                        .tracking(0.6)
                        .foregroundStyle(RouterTheme.ink3)
                    Text(assignedRole.isDescribed ? assignedRole.text : "No description yet.")
                        .font(RouterTheme.sans(11))
                        .foregroundStyle(assignedRole.isDescribed ? RouterTheme.ink2 : RouterTheme.warn)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("PROMPT · SENT TO THE MODEL")
                        .font(RouterTheme.mono(9, .medium))
                        .tracking(0.6)
                        .foregroundStyle(RouterTheme.ink3)
                        .padding(.top, 2)
                    if overriddenByTargetSettings {
                        Text("""
                            This target's own settings set a system_prompt, which wins over the \
                            role's. What the model receives is in Target settings above.
                            """)
                            .font(RouterTheme.sans(10.5))
                            .foregroundStyle(RouterTheme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let prompt = assignedRole.modelPrompt {
                        ReadablePrompt(text: prompt, maxHeight: 180)
                    } else {
                        Text("This role sends no prompt of its own, so the model keeps whatever Codex sends it.")
                            .font(RouterTheme.sans(10.5))
                            .foregroundStyle(RouterTheme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Edit in the library") {
                        editRoleInLibrary = RoleSelection(id: assignedRole.id)
                    }
                        .buttonStyle(.routerGhost)
                }
                .padding(.leading, 28)
            }

        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(RouterTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    role.assignedModel == nil ? RouterTheme.warn.opacity(0.3) : RouterTheme.line,
                    lineWidth: 1
                )
        )
        .sheet(item: $editRoleInLibrary) { selection in
            RolesEditorView(model: model, initialSelection: selection.id)
        }
    }

    /// What the disclosure says before it is opened, so a role with no prompt
    /// of its own does not have to be expanded to find that out.
    private var promptDisclosureTitle: String {
        guard let assignedRole else { return "Role prompt · target has its own wording" }
        return assignedRole.modelPrompt == nil ? "Role prompt · none" : "Role prompt"
    }

    /// Whether this target's own settings already name a system_prompt, which
    /// the generated configuration keeps over the role's.
    private var overriddenByTargetSettings: Bool {
        (role.nativeOptions ?? "").split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && trimmed.hasPrefix("system_prompt")
        }
    }

    private var assignedRole: RoutingRole? { model.role(of: role) }
    private var isClassifier: Bool { model.profile.classifierTargetID == role.id }
    private var isFallback: Bool { model.profile.defaultTargetID == role.id }
    private var hasSettings: Bool { !(role.nativeOptions ?? "").isEmpty }

    /// The menu rows carry the model id; the closed control only has room for
    /// the name, so it shows that and keeps the id in its tooltip.
    private var assignedLabel: String {
        guard let assigned = role.assignedModel else { return "Choose a model…" }
        let entry = model.discoveredModels.first { $0.id == assigned }
        return entry?.displayName ?? assigned
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.profile.tiers.indices.contains(index) ? model.profile.tiers[index].name : "" },
            set: { if model.profile.tiers.indices.contains(index) { model.profile.tiers[index].name = $0 } }
        )
    }

    private var summaryBinding: Binding<String> {
        Binding(
            get: { model.profile.tiers.indices.contains(index) ? model.profile.tiers[index].summary : "" },
            set: { if model.profile.tiers.indices.contains(index) { model.profile.tiers[index].summary = $0 } }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: {
                model.profile.tiers.indices.contains(index)
                    ? (model.profile.tiers[index].assignedModel ?? "") : ""
            },
            set: {
                guard model.profile.tiers.indices.contains(index) else { return }
                model.profile.tiers[index].modelID = $0.isEmpty ? nil : $0
            }
        )
    }

    private var optionsBinding: Binding<String> {
        Binding(
            get: { model.profile.tiers.indices.contains(index) ? model.profile.tiers[index].nativeOptions ?? "" : "" },
            set: {
                guard model.profile.tiers.indices.contains(index) else { return }
                model.profile.tiers[index].nativeOptions = $0.isEmpty ? nil : $0
            }
        )
    }

    private func label(for entry: CodexSubscriptionModel) -> String {
        guard let displayName = entry.displayName, displayName != entry.id else {
            return entry.id
        }
        return "\(displayName) (\(entry.id))"
    }
}
