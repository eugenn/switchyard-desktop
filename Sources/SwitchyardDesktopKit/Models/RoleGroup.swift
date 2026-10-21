import Foundation

/// A reusable collection of roles, optionally associated with a project folder.
/// The path is a label for the user, never a directory the router opens or routes by.
package struct RoleGroup: Codable, Equatable, Identifiable, Sendable {
    package var id: UUID
    package var name: String
    package var projectPath: String?
    /// Optional routing draft, restored explicitly rather than selected by cwd.
    package var routingProfile: RoutingProfile?

    package init(id: UUID = UUID(), name: String, projectPath: String? = nil, routingProfile: RoutingProfile? = nil) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        self.routingProfile = routingProfile
    }

    package var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled group" : trimmed
    }
}
