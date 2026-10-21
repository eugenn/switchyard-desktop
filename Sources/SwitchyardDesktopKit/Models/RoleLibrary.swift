import Foundation

/// Every role this Mac knows about, stored independently of individual setups.
/// A setup takes copies of its roles so it can still restore on its own.
package struct RoleLibrary: Codable, Equatable, Sendable {
    /// Bumped only when a later shape cannot be read by this one.
    package static let currentVersion = 1

    package var version: Int
    /// Shipped and user-written roles together, in the order the library shows
    /// them. A role's `isBuiltIn` says which wording it started as.
    package var roles: [RoutingRole]
    package var groups: [RoleGroup]
    /// Shipped roles the user removed. Without this, every launch would put
    /// them back, and a library that cannot forget a role is not the user's.
    package var hiddenBuiltInIDs: Set<UUID>
    package var savedAt: Date

    package init(
        version: Int = RoleLibrary.currentVersion,
        roles: [RoutingRole] = RoutingRole.builtInCatalog,
        groups: [RoleGroup] = [],
        hiddenBuiltInIDs: Set<UUID> = [],
        savedAt: Date = Date()
    ) {
        self.version = version
        self.roles = roles
        self.groups = groups
        self.hiddenBuiltInIDs = hiddenBuiltInIDs
        self.savedAt = savedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, roles, groups, hiddenBuiltInIDs, savedAt
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        roles = try container.decodeIfPresent([RoutingRole].self, forKey: .roles) ?? []
        groups = try container.decodeIfPresent([RoleGroup].self, forKey: .groups) ?? []
        hiddenBuiltInIDs =
            try container.decodeIfPresent(Set<UUID>.self, forKey: .hiddenBuiltInIDs) ?? []
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
    }

    /// The shipped library, for a Mac that has never opened this screen.
    package static var shipped: RoleLibrary { RoleLibrary() }

    // MARK: - Reading

    /// Roles a target can be given, in library order.
    package var targets: [RoutingRole] { roles.filter { $0.kind == .target } }

    /// Judge prompts. A profile uses one; the library may hold several to pick
    /// between.
    package var classifiers: [RoutingRole] { roles.filter { $0.kind == .classifier } }

    /// Every tag in use, for the filter row. Sorted, so the row does not
    /// reshuffle when a role is edited.
    package var tags: [String] { Set(roles.flatMap(\.tags)).sorted() }

    package subscript(id id: UUID?) -> RoutingRole? {
        guard let id else { return nil }
        return roles.first { $0.id == id }
    }

    /// Roles matching what the library screen is filtering by.
    package func filtered(
        kind: RoutingRole.Kind? = nil, search: String = "", tag: String? = nil,
        groupID: UUID? = nil
    ) -> [RoutingRole] {
        roles.filter { role in
            (kind == nil || role.kind == kind)
                && role.matches(search: search)
                && (tag == nil || role.tags.contains(tag!))
                && (groupID == nil || role.groupIDs.contains(groupID!))
        }
    }

    /// Whether this role still reads the way it shipped, so the screen can
    /// offer to put it back only when that would change something.
    package func isEdited(_ role: RoutingRole) -> Bool {
        guard var shipped = RoutingRole.builtIn(role.id) else { return false }
        shipped.groupIDs = role.groupIDs
        return shipped != role
    }

    // MARK: - Writing

    @discardableResult
    package mutating func addGroup(name: String = "New group", projectPath: String? = nil) -> RoleGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "New group" : trimmed
        let taken = Set(groups.map { $0.displayName.lowercased() })
        var unique = base
        var suffix = 2
        while taken.contains(unique.lowercased()) {
            unique = "\(base) \(suffix)"
            suffix += 1
        }
        let group = RoleGroup(name: unique, projectPath: projectPath)
        groups.append(group)
        return group
    }

    package mutating func updateGroup(_ group: RoleGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
    }

    /// Removing a collection keeps its roles and their other memberships.
    package mutating func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        for index in roles.indices { roles[index].groupIDs.remove(id) }
        for index in groups.indices {
            guard var profile = groups[index].routingProfile else { continue }
            for roleIndex in profile.roles.indices { profile.roles[roleIndex].groupIDs.remove(id) }
            groups[index].routingProfile = profile
        }
    }

    /// Replaces a role, or adds it if the library has never seen it.
    package mutating func upsert(_ role: RoutingRole) {
        if let index = roles.firstIndex(where: { $0.id == role.id }) {
            roles[index] = role
        } else {
            roles.append(role)
        }
        hiddenBuiltInIDs.remove(role.id)
    }

    /// Adds a new role under a name no other role holds, and returns it.
    @discardableResult
    package mutating func add(
        kind: RoutingRole.Kind = .target,
        name: String = "New role",
        text: String = "",
        systemPrompt: String? = nil,
        effort: RoutingRole.Effort? = nil,
        tags: [String] = []
    ) -> RoutingRole {
        let role = RoutingRole(
            kind: kind, name: uniqueName(from: name), text: text,
            systemPrompt: systemPrompt, effort: effort, tags: tags
        )
        roles.append(role)
        return role
    }

    /// Copies a role under its own identity, so the original keeps its wording.
    @discardableResult
    package mutating func duplicate(id: UUID) -> RoutingRole? {
        guard let role = self[id: id] else { return nil }
        let copy = role.duplicate(named: uniqueName(from: "\(role.displayName) copy"))
        let index = roles.firstIndex { $0.id == id }.map { $0 + 1 } ?? roles.count
        roles.insert(copy, at: index)
        return copy
    }

    /// Removes a role. A shipped one is remembered as removed rather than
    /// deleted, so the next launch does not hand it back.
    package mutating func remove(id: UUID) {
        guard let role = self[id: id] else { return }
        roles.removeAll { $0.id == id }
        if RoutingRole.builtIn(role.id) != nil { hiddenBuiltInIDs.insert(role.id) }
    }

    /// Puts a shipped role back the way it was written.
    @discardableResult
    package mutating func resetToBuiltIn(id: UUID) -> RoutingRole? {
        guard var shipped = RoutingRole.builtIn(id) else { return nil }
        shipped.groupIDs = self[id: id]?.groupIDs ?? []
        upsert(shipped)
        return shipped
    }

    /// Adds roles this build ships that the stored library has never held,
    /// skipping the ones the user removed.
    ///
    /// A later version can therefore add roles without overwriting a single
    /// word the user has written, and without resurrecting what they deleted.
    package mutating func mergeShippedRoles() {
        let known = Set(roles.map(\.id)).union(hiddenBuiltInIDs)
        for role in RoutingRole.builtInCatalog where !known.contains(role.id) {
            roles.append(role)
        }
    }

    /// Takes in roles a setup carries that the library does not, so a profile
    /// written before the library existed — or restored from a saved setup —
    /// contributes its wording instead of losing it.
    package mutating func absorb(_ incoming: [RoutingRole]) {
        let known = Set(roles.map(\.id)).union(hiddenBuiltInIDs)
        for role in incoming where !known.contains(role.id) && role.isDescribed {
            var adopted = role
            adopted.name = uniqueName(from: role.displayName)
            roles.append(adopted)
        }
    }

    private func uniqueName(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "New role" : trimmed
        let taken = Set(roles.map { $0.displayName.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }
}

package protocol RoleLibraryStoring: AnyObject, Sendable {
    func load() throws -> RoleLibrary?
    func save(_ library: RoleLibrary) throws
}

/// The library on disk, beside the saved setup and for the same reason: it is
/// the user's writing, not part of any one route.
package final class RoleLibraryStore: RoleLibraryStoring, @unchecked Sendable {
    package static var defaultURL: URL {
        UserDataLocations.supportDirectory.appendingPathComponent("role-library.json")
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package init(fileURL: URL = RoleLibraryStore.defaultURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    package func load() throws -> RoleLibrary? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        var library = try decoder.decode(RoleLibrary.self, from: Data(contentsOf: fileURL))
        // A file written by a later build may hold roles this one cannot read;
        // reading what it can is still better than replacing the user's work.
        library.mergeShippedRoles()
        return library
    }

    package func save(_ library: RoleLibrary) throws {
        var stored = library
        stored.savedAt = Date()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(stored).write(to: fileURL, options: .atomic)
    }
}
