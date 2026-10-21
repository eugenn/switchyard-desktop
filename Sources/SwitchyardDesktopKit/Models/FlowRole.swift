import Foundation

/// The role a destination serves on the flow map: the name the user gave that
/// group of work, and how hard the role asks its model to think.
///
/// The map orders its rows by this effort rather than by traffic, so the column
/// reads top to bottom as heavy work down to cheap work, and a row keeps its
/// place while the counters move under it.
package struct FlowRole: Equatable, Sendable {
    package let name: String
    /// Left `nil`, the role says nothing about effort and the model keeps its
    /// own default -- which is not a level the map can place on the ladder.
    package let effort: RoutingRole.Effort?

    /// Where the role sits on the ladder, heaviest highest. A role naming no
    /// effort ranks below every role that does.
    package var rank: Int {
        guard let effort, let level = RoutingRole.Effort.allCases.firstIndex(of: effort) else {
            return -1
        }
        return level
    }

    /// How many steps the ladder has, so the row's mark and the ordering are
    /// drawn against the same scale.
    package static var levels: Int { RoutingRole.Effort.allCases.count }

    /// Shares in the order the flow map draws them: heaviest role first, then
    /// the busier of two rows at the same level, then by name so rows never
    /// swap places under a live counter.
    ///
    /// With no role known at all there is no ladder to order by, so the shares
    /// keep the order the metrics computed them in -- busiest first.
    package static func ordered(
        _ shares: [RoutingMetrics.Share],
        roles: [String: FlowRole]
    ) -> [RoutingMetrics.Share] {
        guard !roles.isEmpty else { return shares }
        return shares.sorted { left, right in
            let leftRank = roles[left.id]?.rank ?? -1
            let rightRank = roles[right.id]?.rank ?? -1
            if leftRank != rightRank { return leftRank > rightRank }
            if left.count != right.count { return left.count > right.count }
            return left.id < right.id
        }
    }
}
