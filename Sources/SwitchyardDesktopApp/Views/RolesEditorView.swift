import SwitchyardDesktopKit
import SwiftUI

/// The role library: every role this Mac knows, what each one tells the judge
/// and the model, and which of them this setup uses.
///
/// Roles used to be written inside the setup that held them, so the same
/// wording was retyped for every setup and reusable prompts
/// were hard to find. The library is written once and picked from
/// everywhere; a setup takes a copy of what it uses, and an edit here follows
/// into it.
struct RolesEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: WizardModel
    /// Which role to open on. Tests pin it; the screen otherwise starts on the
    /// judge prompt this setup uses.
    var initialSelection: UUID?
    var initialGroupSelection: UUID?
    @State private var selection: UUID?
    @State private var search = ""
    @State private var tagFilter: String?
    @State private var groupFilter: UUID?
    @State private var showsGroupEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            RouterDivider()
            HStack(spacing: 0) {
                roleList
                RouterDivider().frame(width: 1)
                detail
            }
            .frame(maxHeight: .infinity)
            RouterDivider()
            footer
        }
        .frame(width: 940, height: 640)
        .background(RouterTheme.win)
        .foregroundStyle(RouterTheme.ink)
        .environment(\.colorScheme, .dark)
        .onAppear {
            if groupFilter == nil { groupFilter = initialGroupSelection }
            if selection == nil {
                selection = initialSelection ?? model.classifierRole?.id ?? library.targets.first?.id
            }
        }
        .onChange(of: groupFilter) { _, _ in
            let matching = library.filtered(search: search, tag: tagFilter, groupID: groupFilter)
            if !matching.contains(where: { $0.id == selection }) { selection = matching.first?.id }
        }
    }

    private var library: RoleLibrary { model.roleLibrary }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Role library").font(.system(size: 21, weight: .semibold))
                Text("""
                    A role is the work a target takes: what the judge is told about it, what the \
                    model serving it is told to do, and how hard it thinks. Roles are kept for \
                    every setup on this Mac — edit one here and every target holding it follows.
                    """)
                    .font(RouterTheme.sans(12))
                    .foregroundStyle(RouterTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            searchField
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(RouterTheme.ink3)
            TextField("Search roles", text: $search)
                .textFieldStyle(.plain)
                .font(RouterTheme.sans(12))
                .foregroundStyle(RouterTheme.ink)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RouterTheme.ink3)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 240)
        .background(RouterTheme.sunk, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RouterTheme.line))
        .accessibilityLabel("Search roles")
    }

    // MARK: - List

    /// Roles this setup carries, and the rest of the library, each already
    /// filtered by the search and tag the screen is showing.
    private var shown: (inSetup: [RoutingRole], rest: [RoutingRole]) {
        let matching = library.filtered(search: search, tag: tagFilter, groupID: groupFilter)
        return (matching.filter { model.isRoleInSetup($0) }, matching.filter { !model.isRoleInSetup($0) })
    }

    private var roleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupRow
            RouterDivider()
            tagRow
            RouterDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let groups = shown
                    if !groups.inSetup.isEmpty {
                        SectionLabel("In this setup").padding(.horizontal, 10).padding(.top, 2)
                        ForEach(groups.inSetup) { listRow($0) }
                    }
                    if !groups.rest.isEmpty {
                        SectionLabel("Library")
                            .padding(.top, groups.inSetup.isEmpty ? 2 : 10)
                            .padding(.horizontal, 10)
                        ForEach(groups.rest) { listRow($0) }
                    }
                    if groups.inSetup.isEmpty && groups.rest.isEmpty {
                        Text("No role matches this search.")
                            .font(RouterTheme.sans(11.5))
                            .foregroundStyle(RouterTheme.ink3)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                    }
                }
                .padding(10)
            }
            RouterDivider()
            HStack(spacing: 8) {
                Button {
                    var role = model.addRole()
                    if let groupFilter {
                        role.groupIDs.insert(groupFilter)
                        model.updateRole(role)
                    }
                    selection = role.id
                    search = ""
                    tagFilter = nil
                } label: {
                    Label("New role", systemImage: "plus")
                }
                .buttonStyle(.routerGhost)
                Spacer(minLength: 0)
                Button {
                    groupFilter = model.addRoleGroup().id
                    showsGroupEditor = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.routerGhost)
                .help("New project or role group")
                .accessibilityLabel("New role group")
            }
            .padding(10)
        }
        .frame(width: 272)
    }

    private var selectedGroup: RoleGroup? { library.groups.first { $0.id == groupFilter } }

    private var groupRow: some View {
        HStack(spacing: 6) {
            Menu {
                Button("All groups") { groupFilter = nil }
                Divider()
                ForEach(library.groups) { group in
                    Button(group.displayName) { groupFilter = group.id }
                }
            } label: {
                Label(selectedGroup?.displayName ?? "All groups", systemImage: "folder")
                    .font(RouterTheme.sans(12, .medium))
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Filter by project or group")
            if selectedGroup != nil {
                Button { showsGroupEditor = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit role group")
            }
        }
        .padding(10)
        .popover(isPresented: $showsGroupEditor) {
            if let group = selectedGroup { groupEditor(group) }
        }
    }

    private func groupEditor(_ group: RoleGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project / group").font(RouterTheme.sans(14, .semibold))
            TextField("Group name", text: groupBinding(group, path: false))
                .accessibilityLabel("Group name")
            TextField("Project folder (optional)", text: groupBinding(group, path: true))
                .accessibilityLabel("Group project folder")
            Text("The folder identifies the project. Use saved setup to load its routing; it does not switch automatically.")
                .font(RouterTheme.sans(11))
                .foregroundStyle(RouterTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let saved = group.routingProfile {
                Text("\(saved.algorithm?.displayName ?? "Draft") · \(saved.tiers.count) targets")
                    .font(RouterTheme.sans(11, .medium))
                Button("Use saved setup") {
                    if model.loadRoleGroupSetup(id: group.id) { showsGroupEditor = false }
                }
                .buttonStyle(.routerPrimary)
                .disabled(!model.canLoadRoleGroupSetup)
                if !model.canLoadRoleGroupSetup {
                    Text("Stop routing before loading another setup.")
                        .font(RouterTheme.sans(11)).foregroundStyle(RouterTheme.warn)
                }
            }
            Button(group.routingProfile == nil ? "Save current setup" : "Replace with current setup") {
                model.saveSetupToRoleGroup(id: group.id)
            }
            .buttonStyle(.routerGhost)
            .disabled(!model.profile.isValid)
            RouterDivider()
            Button("Remove group, keep roles") {
                model.removeRoleGroup(id: group.id)
                groupFilter = nil
                showsGroupEditor = false
            }
            .buttonStyle(.routerGhost)
        }
        .padding(16)
        .frame(width: 330)
        .background(RouterTheme.panel)
        .environment(\.colorScheme, .dark)
    }

    private func groupBinding(_ group: RoleGroup, path: Bool) -> Binding<String> {
        Binding(
            get: {
                let current = library.groups.first { $0.id == group.id } ?? group
                return path ? current.projectPath ?? "" : current.name
            },
            set: { value in
                guard var current = library.groups.first(where: { $0.id == group.id }) else { return }
                if path {
                    current.projectPath = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                } else {
                    current.name = value
                }
                model.updateRoleGroup(current)
            }
        )
    }

    private func membershipRow(_ role: RoutingRole) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Menu {
                if library.groups.isEmpty { Text("Create a group using the folder button") }
                ForEach(library.groups) { group in
                    Toggle(group.displayName, isOn: Binding(
                        get: { library[id: role.id]?.groupIDs.contains(group.id) ?? false },
                        set: { included in
                            edit(role) {
                                if included { $0.groupIDs.insert(group.id) }
                                else { $0.groupIDs.remove(group.id) }
                            }
                        }
                    ))
                }
            } label: {
                Label("Groups", systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            let names = library.groups.filter { role.groupIDs.contains($0.id) }.map(\.displayName)
            Text(names.isEmpty ? "No group" : names.joined(separator: " · "))
                .font(RouterTheme.sans(11))
                .foregroundStyle(RouterTheme.ink2)
                .textSelection(.enabled)
        }
    }

    private var tagRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                tagChip(title: "All", tag: nil)
                ForEach(library.tags, id: \.self) { tag in
                    tagChip(title: tag, tag: tag)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func tagChip(title: String, tag: String?) -> some View {
        let selected = tagFilter == tag
        return Button {
            tagFilter = selected ? nil : tag
        } label: {
            Text(title)
                .font(RouterTheme.sans(10.5, selected ? .medium : .regular))
                .foregroundStyle(selected ? RouterTheme.accent : RouterTheme.ink2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(selected ? RouterTheme.accent.opacity(0.14) : RouterTheme.panel2)
                )
                .overlay(Capsule().strokeBorder(selected ? RouterTheme.accent.opacity(0.35) : RouterTheme.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag == nil ? "Show every role" : "Filter by \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func listRow(_ role: RoutingRole) -> some View {
        let selected = selection == role.id
        return Button {
            selection = role.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(role.displayName)
                        .font(RouterTheme.sans(12.5, .medium))
                        .foregroundStyle(RouterTheme.ink)
                        .lineLimit(1)
                    if role.kind == .classifier { RouterFlag(text: "judge", tint: RouterTheme.p95) }
                    Spacer(minLength: 0)
                    if role.modelPrompt != nil {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 9))
                            .foregroundStyle(RouterTheme.ink3)
                            .help("Has a prompt for the model")
                    }
                    if let effort = role.effort { RouterFlag(text: effort.rawValue) }
                }
                Text(subtitle(for: role))
                    .font(RouterTheme.sans(10.5))
                    .foregroundStyle(RouterTheme.ink3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? RouterTheme.panel2 : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? RouterTheme.line2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// What the row says under the name: where the role is used, or what is
    /// wrong with it, since the list is where an unfinished role has to show.
    private func subtitle(for role: RoutingRole) -> String {
        if role.kind == .classifier {
            if !role.rendersTargets { return "Missing \(RoutingRole.targetsPlaceholder)" }
            return model.classifierRole?.id == role.id ? "The judge's prompt" : "Judge prompt, unused"
        }
        if !role.isDescribed { return "No description yet" }
        let holders = model.targetsHolding(role).count
        switch holders {
        case 0: return model.isRoleInSetup(role) ? "In this setup, held by no target" : tagLine(role)
        case 1: return "Held by 1 target"
        default: return "Held by \(holders) targets"
        }
    }

    private func tagLine(_ role: RoutingRole) -> String {
        role.tags.isEmpty ? "In the library" : role.tags.joined(separator: " · ")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let role = library[id: selection] {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameRow(role)
                    usageRow(role)
                    membershipRow(role)
                    if role.kind == .classifier {
                        judgeModelLine
                        classifierHelp
                    } else {
                        targetHelp(role)
                    }
                    editor(
                        for: textBinding(role),
                        mono: role.kind == .classifier,
                        height: role.kind == .classifier ? 330 : 120,
                        label: role.kind == .classifier
                            ? "Judge prompt" : "\(role.displayName) description"
                    )
                    if role.kind == .target { systemPromptSection(role) }
                    warnings(role)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity)
        } else {
            ContentUnavailableView(
                "Select a role",
                systemImage: "text.alignleft",
                description: Text("Pick a role on the left to change its wording, prompt and reasoning.")
            )
            .frame(maxWidth: .infinity)
        }
    }

    private func editor(
        for text: Binding<String>, mono: Bool, height: CGFloat, label: String
    ) -> some View {
        TextEditor(text: text)
            .font(mono ? RouterTheme.mono(12) : RouterTheme.sans(12.5))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .padding(12)
            .frame(height: height)
            .background(RouterTheme.sunk, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(RouterTheme.line))
            .accessibilityLabel(label)
    }

    private func nameRow(_ role: RoutingRole) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Name")
                TextField("Role name", text: nameBinding(role))
                    .textFieldStyle(.plain)
                    .font(RouterTheme.sans(15, .medium))
                    .foregroundStyle(RouterTheme.ink)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(RouterTheme.line2).frame(height: 1).offset(y: 4)
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Tags")
                TextField("Add tags…", text: tagBinding(role))
                    .textFieldStyle(.plain)
                    .font(RouterTheme.sans(12))
                    .foregroundStyle(RouterTheme.ink2)
                    .frame(width: 180)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(RouterTheme.line2).frame(height: 1).offset(y: 4)
                    }
                    .help("Comma-separated, used by the filter row on the left")
            }
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Reasoning")
                RouterMenu(
                    value: role.effort?.displayName ?? "Model default",
                    placeholder: role.effort == nil
                ) {
                    Button("Model default") { model.updateRole(role.with(effort: nil)) }
                    Divider()
                    ForEach(RoutingRole.Effort.allCases) { level in
                        Button(level.displayName) { model.updateRole(role.with(effort: level)) }
                    }
                }
                .frame(width: 150)
            }
        }
    }

    /// Where this role stands in the current setup, and everything that can be
    /// done to the role itself.
    private func usageRow(_ role: RoutingRole) -> some View {
        HStack(spacing: 8) {
            if model.isRoleInSetup(role) {
                Label(usageText(role), systemImage: "checkmark.circle")
                    .font(RouterTheme.sans(11))
                    .foregroundStyle(RouterTheme.accent)
            } else {
                Button {
                    model.useRoleInSetup(role.id)
                } label: {
                    Label("Add to this setup", systemImage: "plus.circle")
                }
                .buttonStyle(.routerSmall)
                .help(role.kind == .classifier
                      ? "Make this the judge prompt for the current setup"
                      : "Offer this role to the targets of the current setup")
            }
            if role.isBuiltIn { RouterTag(text: "built-in") }
            Spacer(minLength: 0)
            Button {
                if let copy = model.duplicateRole(id: role.id) { selection = copy.id }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.routerGhost)
            if library.isEdited(role) {
                Button("Reset to built-in") { model.resetRoleToBuiltIn(id: role.id) }
                    .buttonStyle(.routerGhost)
                    .help("Put the shipped wording, prompt and reasoning back")
            }
            Button {
                model.removeRole(id: role.id)
                selection = library.targets.first?.id ?? library.roles.first?.id
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .buttonStyle(.routerGhost)
            .disabled(isSetupJudge(role))
            .help(isSetupJudge(role)
                  ? "This is the judge prompt this setup runs on. Put another one in use first."
                  : "Remove from the library. Targets holding it keep its wording.")
        }
    }

    /// Whether removing this role would take the running setup's judge prompt
    /// with it.
    private func isSetupJudge(_ role: RoutingRole) -> Bool {
        role.kind == .classifier && model.classifierRole?.id == role.id
    }

    private func usageText(_ role: RoutingRole) -> String {
        if role.kind == .classifier {
            return model.classifierRole?.id == role.id ? "The judge prompt of this setup" : "In this setup"
        }
        let holders = model.targetsHolding(role)
        guard !holders.isEmpty else { return "In this setup, held by no target" }
        return "Held by " + holders.map(\.displayName).formattedList()
    }

    /// Which model this prompt actually runs on. A classifier role is a prompt,
    /// not a target, so the question "where do I give it a model?" has to be
    /// answered on the screen that raises it.
    @ViewBuilder
    private var judgeModelLine: some View {
        if model.profile.algorithm?.requiresJudge == true {
            HStack(spacing: 6) {
                Image(systemName: model.profile.classifierModel == nil
                      ? "exclamationmark.triangle" : "cpu")
                    .font(.system(size: 10))
                Text(judgeModelSummary)
                    .font(RouterTheme.sans(11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(model.profile.classifierModel == nil ? RouterTheme.warn : RouterTheme.ink2)
        }
    }

    private var judgeModelSummary: String {
        guard let id = model.profile.classifierModel else {
            return "No model decides the routing yet — pick one under Routing decisions on the "
                + "routing step."
        }
        let name = model.discoveredModels.first { $0.id == id }?.displayName ?? id
        if model.profile.judgeModelID != nil {
            return "Runs on \(name), a model of its own. Changed under Routing decisions."
        }
        return "Runs on \(name), shared with the target that makes the call. Changed under "
            + "Routing decisions."
    }

    private var classifierHelp: some View {
        Text("""
            \(RoutingRole.targetsPlaceholder) is replaced by one line per target, built from the \
            roles it holds, so the prompt can never name a target that no longer exists. \
            \(RoutingRole.targetNamesPlaceholder) becomes their comma-separated keys. Reasoning \
            applies when the judge runs on a model of its own.
            """)
            .font(RouterTheme.sans(11.5))
            .foregroundStyle(RouterTheme.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func targetHelp(_ role: RoutingRole) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel("Description · read by the judge")
            Text("""
                The judge reads this and nothing else to decide whether a request belongs here. \
                Say what the work looks like, and what it is not. Reasoning becomes \
                reasoning_effort on every target holding this role.
                """)
                .font(RouterTheme.sans(11.5))
                .foregroundStyle(RouterTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func systemPromptSection(_ role: RoutingRole) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Prompt · sent to the model")
                    Text("""
                        Written onto the target as system_prompt, so the model serving this role \
                        is told how to work. Left empty, the model is sent no prompt of its own.
                        """)
                        .font(RouterTheme.sans(11.5))
                        .foregroundStyle(RouterTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            editor(
                for: promptBinding(role), mono: false, height: 200,
                label: "\(role.displayName) prompt"
            )
        }
    }

    @ViewBuilder
    private func warnings(_ role: RoutingRole) -> some View {
        if role.kind == .classifier, !role.rendersTargets {
            RouterNote(
                systemImage: "exclamationmark.triangle",
                text: "Put \(RoutingRole.targetsPlaceholder) back — without it the judge never sees "
                    + "the groups it is asked to choose between, and every turn falls through to "
                    + "the fallback target.",
                tint: RouterTheme.warn
            )
        }
        if role.kind == .target, !role.isDescribed, model.isRoleInSetup(role) {
            RouterNote(
                systemImage: "exclamationmark.triangle",
                text: "Describe the work, or the judge has nothing to tell this group apart from "
                    + "the others.",
                tint: RouterTheme.warn
            )
        }
        let unsupported = model.unsupportedEffortModels(for: role)
        if !unsupported.isEmpty, let effort = role.effort {
            RouterNote(
                systemImage: "exclamationmark.triangle",
                text: "\(unsupported.formattedList()) does not list \(effort.rawValue) reasoning. "
                    + "Switchyard forwards it anyway and the upstream decides.",
                tint: RouterTheme.warn
            )
        }
        if let error = model.roleLibraryError {
            RouterNote(systemImage: "externaldrive.badge.exclamationmark", text: error, tint: RouterTheme.warn)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(library.targets.count) roles in the library · \(model.targetRoles.count) in this setup")
                .font(RouterTheme.sans(11))
                .foregroundStyle(RouterTheme.ink3)
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .buttonStyle(.routerPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(RouterTheme.mono(10, .medium))
            .tracking(0.6)
            .foregroundStyle(RouterTheme.ink3)
    }

    // MARK: - Bindings

    /// Every field edits the library role and lets the model carry the change
    /// into the setup, so a target never drifts from the role it holds.
    private func edit(_ role: RoutingRole, _ change: (inout RoutingRole) -> Void) {
        guard var edited = library[id: role.id] else { return }
        change(&edited)
        model.updateRole(edited)
    }

    private func nameBinding(_ role: RoutingRole) -> Binding<String> {
        Binding(
            get: { library[id: role.id]?.name ?? "" },
            set: { name in edit(role) { $0.name = name } }
        )
    }

    private func textBinding(_ role: RoutingRole) -> Binding<String> {
        Binding(
            get: { library[id: role.id]?.text ?? "" },
            set: { text in edit(role) { $0.text = text } }
        )
    }

    private func promptBinding(_ role: RoutingRole) -> Binding<String> {
        Binding(
            get: { library[id: role.id]?.systemPrompt ?? "" },
            set: { prompt in
                edit(role) {
                    // An emptied field is no prompt at all, not an empty one:
                    // the target then ships none rather than an empty string.
                    $0.systemPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : prompt
                }
            }
        )
    }

    /// Tags as the user types them, normalised only on the way into the role.
    private func tagBinding(_ role: RoutingRole) -> Binding<String> {
        Binding(
            get: { library[id: role.id]?.tags.joined(separator: ", ") ?? "" },
            set: { text in
                edit(role) { $0.tags = RoutingRole.normalized(text.components(separatedBy: ",")) }
            }
        )
    }
}
