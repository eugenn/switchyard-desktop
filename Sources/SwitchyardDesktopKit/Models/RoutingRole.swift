import Foundation

/// A named, reusable description of the work a target takes, and how hard the
/// model holding it should think.
///
/// Targets used to carry their own name and description, which meant the same
/// wording was retyped for every setup and the judge prompt drifted from the
/// targets it names. A role is written once and picked from a list; editing it
/// reaches every target holding it.
package struct RoutingRole: Codable, Equatable, Identifiable, Sendable {
    /// What a role describes. The list holds exactly one classifier.
    package enum Kind: String, Codable, Sendable {
        /// The work one group of requests takes.
        case target
        /// The judge's own instructions, into which the groups are rendered.
        case classifier
    }

    /// `reasoning_effort` for a target holding this role.
    ///
    /// Switchyard forwards the value untouched, so what a model accepts is the
    /// model's own business: these are the levels Codex's catalog lists, in
    /// ascending order. A role may name a level a given model does not support,
    /// which is why the assignment step checks it against the model.
    package enum Effort: String, Codable, CaseIterable, Identifiable, Sendable {
        case low, medium, high, xhigh, max, ultra

        package var id: String { rawValue }

        package var displayName: String {
            switch self {
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            case .xhigh: "Extra high"
            case .max: "Max"
            case .ultra: "Ultra"
            }
        }
    }

    /// Where the generated list of groups goes in a classifier role's text.
    package static let targetsPlaceholder = "{{targets}}"
    /// Where the group names go, for a classifier role that restates the
    /// answer contract in prose.
    package static let targetNamesPlaceholder = "{{target_names}}"

    package var id: UUID
    package var kind: Kind
    package var name: String
    /// A target role: the work it takes, handed to the judge as that group's
    /// description. A classifier role: the judge's whole prompt, with
    /// `{{targets}}` marking where the generated group list goes.
    package var text: String
    /// Instructions the model serving a target holding this role is given, as
    /// `system_prompt` on the generated target.
    ///
    /// Separate from `text`, which only ever reaches the judge: the judge is
    /// told what the group is for, while the model is told how to work. Left
    /// `nil`, the target ships no prompt of its own and the model keeps
    /// whatever the client sends it.
    package var systemPrompt: String?
    /// Free-form categories the library filters by. Lowercased on the way in,
    /// so a filter never misses a role over its capitalisation.
    package var tags: [String]
    /// A role can be reused in several projects without copying its prompt.
    package var groupIDs: Set<UUID>
    /// Left `nil`, the target says nothing about effort and the model keeps its
    /// own default.
    ///
    /// On the classifier role this is the judge's own effort, which applies
    /// only where the judge is a target of its own — a judge sharing a
    /// completion target already runs at that target's role's effort.
    package var effort: Effort?
    /// Built-in roles are offered on a fresh profile and may be edited like any
    /// other. The flag only marks where the wording came from.
    package var isBuiltIn: Bool

    package init(
        id: UUID = UUID(),
        kind: Kind = .target,
        name: String,
        text: String,
        systemPrompt: String? = nil,
        effort: Effort? = nil,
        tags: [String] = [],
        groupIDs: Set<UUID> = [],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.text = text
        self.systemPrompt = systemPrompt
        self.effort = effort
        self.tags = Self.normalized(tags)
        self.groupIDs = groupIDs
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, text, systemPrompt, effort, tags, groupIDs, isBuiltIn
    }

    /// A role saved before prompts and tags existed carries neither, and must
    /// decode to the same role it was rather than to a failure.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .target
        name = try container.decode(String.self, forKey: .name)
        text = try container.decode(String.self, forKey: .text)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        effort = try container.decodeIfPresent(Effort.self, forKey: .effort)
        tags = Self.normalized(try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
        groupIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .groupIDs) ?? []
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    /// Trimmed, lowercased, de-duplicated tags in the order they were given.
    package static func normalized(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    package var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled role" : trimmed
    }

    /// A target role with nothing to say leaves the judge unable to tell its
    /// group from any other.
    package var isDescribed: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A classifier role has to say where the groups go, or the judge is asked
    /// to choose between targets it was never shown.
    package var rendersTargets: Bool {
        kind != .classifier || text.contains(Self.targetsPlaceholder)
    }

    /// The prompt the model gets, treating whitespace as no prompt at all.
    package var modelPrompt: String? {
        guard let systemPrompt,
              !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return systemPrompt
    }

    /// A copy at a different effort, for a picker that edits one field.
    package func with(effort: Effort?) -> RoutingRole {
        var copy = self
        copy.effort = effort
        return copy
    }

    /// Whether a library search matches this role. Name, wording, prompt and
    /// tags all count: a role is as easily remembered by a phrase inside its
    /// prompt as by its name.
    package func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return [name, text, systemPrompt ?? ""].contains { $0.lowercased().contains(query) }
            || tags.contains { $0.contains(query) }
    }

    /// A copy under a new identity, for duplicating a role in the library.
    package func duplicate(named name: String) -> RoutingRole {
        RoutingRole(
            kind: kind, name: name, text: text, systemPrompt: systemPrompt,
            effort: effort, tags: tags, groupIDs: groupIDs, isBuiltIn: false
        )
    }

    // MARK: - Defaults

    /// Built-in ids are fixed, so the same role is the same role in every
    /// profile and a saved target keeps pointing at it.
    package static func builtInID(_ index: UInt8) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0x0D  // "role"
        bytes[15] = index
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The judge prompt this app has always generated, as an editable template.
    ///
    /// Low effort by default: the judge weighs one short classification per
    /// turn against descriptions written for exactly that, and it runs on every
    /// request, so anything deeper is latency and spend on each turn rather
    /// than a better choice.
    package static var builtInClassifier: RoutingRole {
        RoutingRole(
            id: builtInID(0),
            kind: .classifier,
            name: "Classifier",
            text: """
                Choose the best group for this request.

                \(targetsPlaceholder)

                Do not answer or perform the request. Classify it.
                Reply with this JSON object and nothing else:
                {"decision": {"target": "<one of: \(targetNamesPlaceholder)>"}}
                """,
            effort: .low,
            isBuiltIn: true
        )
    }

    /// Four levels of work, from a change that is already spelled out to one
    /// whose approach is still in question — the ladder a subscription's own
    /// model line is built around.
    package static var builtInTargets: [RoutingRole] {
        [
            RoutingRole(
                id: builtInID(1),
                name: "Direct",
                text: """
                    One named file or function, changed the way the request already \
                    describes: apply a stated fix, add a straightforward test, adjust \
                    copy or configuration, answer a question about code already in view. \
                    Not for changes that need a cause found first.
                    """,
                systemPrompt: """
                    Carry out the change exactly as described, and nothing beside it. \
                    Read the named file before editing it, follow the conventions already \
                    in it, and keep the edit as small as the request allows. Do not \
                    refactor, rename or reformat code the request did not name. If the \
                    request turns out to rest on something that is not true of this code, \
                    say so in one line instead of guessing. Report what you changed and \
                    what you ran, and never claim a check passed unless it actually ran.
                    """,
                effort: .low,
                tags: ["coding", "quick"],
                isBuiltIn: true
            ),
            RoutingRole(
                id: builtInID(2),
                name: "Standard",
                text: """
                    Ordinary feature and bug work over a handful of related files where \
                    the goal is clear but the steps are not: implement described \
                    behaviour, fix a bug that has a reproduction, extend existing tests. \
                    The right choice whenever a turn is routine but not trivial.
                    """,
                systemPrompt: """
                    Work through ordinary feature and bug work end to end. Read the \
                    surrounding code before changing it, reuse the patterns already \
                    established there, and make the smallest complete change that \
                    satisfies the request. Keep unrelated behaviour intact. Verify what \
                    you changed with the project's own tests or a focused check, and if an \
                    assumption fails, diagnose the new evidence rather than repeating the \
                    attempt. Report what changed, what you verified, and anything you left \
                    undone.
                    """,
                effort: .medium,
                tags: ["coding"],
                isBuiltIn: true
            ),
            RoutingRole(
                id: builtInID(3),
                name: "Investigative",
                text: """
                    Work that must be investigated before it can be written: a failure \
                    with no reproduction, a regression of unknown origin, changes cutting \
                    across modules or public interfaces, non-trivial concurrency, \
                    performance or migration work, or a long tool-driven session that has \
                    to stay coherent.
                    """,
                systemPrompt: """
                    Find the cause before writing the fix. Gather the evidence the \
                    codebase and tool output actually give you, form a hypothesis, and \
                    test it rather than patching the symptom. Say which of your \
                    conclusions are measured and which are still assumptions. Once the \
                    cause is established, make the change that addresses it, keep the \
                    blast radius to what the cause requires, and verify the behaviour that \
                    was broken. Do not repeat an approach the session has already shown to \
                    fail, and never report a check as passing unless it ran.
                    """,
                effort: .high,
                tags: ["coding", "debugging"],
                isBuiltIn: true
            ),
            RoutingRole(
                id: builtInID(4),
                name: "Architectural",
                text: """
                    Turns where the right approach is itself in question: architecture and \
                    system design, ambiguous or conflicting requirements, decisions \
                    critical to security or data integrity, subtle bugs that survived an \
                    earlier attempt, and anything escalated after a weaker answer.
                    """,
                systemPrompt: """
                    Decide the approach before committing to code. Name the constraints \
                    that actually bind, the options worth considering and the trade-off \
                    that settles between them, and say plainly where a requirement is \
                    ambiguous instead of resolving it silently. Weigh security, data \
                    integrity and the cost of being wrong. Then implement the choice you \
                    argued for, keeping the change coherent with the architecture already \
                    in place, and verify it. Distinguish what you measured from what you \
                    reasoned about.
                    """,
                effort: .xhigh,
                tags: ["architecture", "planning"],
                isBuiltIn: true
            ),
        ]
    }

    /// What a fresh profile starts with: the judge's prompt and the ladder.
    /// The library offers the rest.
    package static var builtIns: [RoutingRole] { [builtInClassifier] + builtInTargets }
}

package extension Array where Element == RoutingRole {
    /// The one classifier role, which every classifier route needs.
    package var classifier: RoutingRole? { first { $0.kind == .classifier } }

    /// Roles a target can be given, in the order they are offered.
    package var targets: [RoutingRole] { filter { $0.kind == .target } }

    package subscript(id id: UUID?) -> RoutingRole? {
        guard let id else { return nil }
        return first { $0.id == id }
    }
}
