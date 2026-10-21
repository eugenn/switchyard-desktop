import Foundation

/// One ordered routing target: the work it should handle and its assigned
/// subscription model. `stage_router` uses the fixed Efficient and Capable
/// roles, while `llm_classifier` lets the user define two to six targets.
package struct TaskTier: Codable, Equatable, Identifiable, Sendable {
    /// Bounds apply only to the classifier's ordered target list.
    package static let minimumCount = 2
    package static let maximumCount = 6

    package var id: UUID
    package var name: String
    /// The work this target should take. Shown in the wizard and handed to the
    /// classifier as its description.
    package var summary: String
    /// Model id assigned to this tier, or `nil` while it is unassigned.
    package var modelID: String?
    /// Native target settings, e.g. system_prompt, reasoning_effort and extra_body.
    package var nativeOptions: String?
    /// Preserves target references when restoring a native deployment.
    package var targetKey: String?
    /// The role this target holds. `name` and `summary` are kept in step with
    /// it, so everything that reads a target keeps reading the target.
    package var roleID: UUID?

    package init(id: UUID = UUID(), name: String, summary: String, modelID: String? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.modelID = modelID
    }

    /// The assigned model, treating an empty string as unassigned.
    package var assignedModel: String? {
        modelID.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    package var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled tier" : trimmed
    }

    /// Candidate `[targets.<name>]` key derived from the tier's name. Not
    /// guaranteed unique on its own — use `[TaskTier].targetNames`.
    package var slugSeed: String {
        var slug = ""
        var lastWasSeparator = true  // suppresses a leading underscore
        for character in displayName.lowercased() {
            if character.isLetter || character.isNumber, character.isASCII {
                slug.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                slug.append("_")
                lastWasSeparator = true
            }
        }
        while slug.hasSuffix("_") { slug.removeLast() }
        if let first = slug.first, first.isNumber { slug = "t\(slug)" }
        return String(slug.prefix(24))
    }

    // MARK: - Defaults

    /// `stage_router` has exactly these two non-editable roles.
    package static var stageRouterDefaults: [TaskTier] {
        [
            TaskTier(
                name: "Efficient",
                summary: """
                    Serves routine tool continuations when stage signals allow it.
                    """
            ),
            TaskTier(
                name: "Capable",
                summary: """
                    Handles escalation, error recovery and difficult turns.
                    """
            ),
        ]
    }

    /// A classifier begins with two targets. The user can add up to six.
    ///
    /// Descriptions start empty so the field shows its own prompt: earlier
    /// builds pre-filled instructional text, which reads as a finished answer
    /// and reached the judge verbatim.
    package static var classifierDefaults: [TaskTier] {
        [
            TaskTier(name: "Target 1", summary: ""),
            TaskTier(name: "Target 2", summary: ""),
        ]
    }

    /// A fresh classifier target, named so it does not collide with an existing
    /// target role.
    package static func newTier(among existing: [TaskTier]) -> TaskTier {
        let taken = Set(existing.map { $0.displayName.lowercased() })
        var index = existing.count + 1
        var name = "Target \(index)"
        while taken.contains(name.lowercased()) {
            index += 1
            name = "Target \(index)"
        }
        return TaskTier(name: name, summary: "")
    }

    // MARK: - Descriptions

    /// Instructional text earlier builds pre-filled into a new classifier
    /// target. It describes the field rather than the work, so it must never
    /// reach the judge: a prompt whose roles all read alike leaves the judge
    /// nothing to tell them apart and every turn falls through to the route's
    /// default target. Saved setups still carry it, so it stays recognized.
    package static let legacySummaryPlaceholders = [
        "Describe the work this target should handle.",
        "Describe the work this tier should handle.",
    ]

    /// Whether this role still lacks a description of its own. Only a
    /// classifier hands descriptions to a judge; stage routing ships real ones.
    package var needsSummary: Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || Self.legacySummaryPlaceholders.contains {
                trimmed.caseInsensitiveCompare($0) == .orderedSame
            }
    }
}

package extension Array where Element == TaskTier {
    /// Category names Switchyard reserves in a route's `models` table. A
    /// classifier route names one model group per tier, so a tier whose slug
    /// landed on `any` would claim the route's whole fallback pool and one on
    /// `judge` would claim the judge candidates — and `judge` is not routable at
    /// all, so the judge's own verdict for that tier could never be served.
    package static let reservedTargetNames: Set<String> = ["any", "judge"]

    /// Unique, TOML-safe target names positionally matching the tiers.
    package var targetNames: [String] {
        var used: Set<String> = Self.reservedTargetNames
        return enumerated().map { index, tier in
            var base = tier.slugSeed
            if base.isEmpty { base = "tier\(index + 1)" }
            var candidate = base
            var suffix = 2
            while used.contains(candidate) {
                candidate = "\(base)\(suffix)"
                suffix += 1
            }
            used.insert(candidate)
            return candidate
        }
    }
}
