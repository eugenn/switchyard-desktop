import Foundation
import Observation

/// One app-wide beat telling its subscribers that derived figures are due for
/// a recalculation. Subscribers are awaited in turn on every beat, so whatever
/// recalculates on it does so together instead of drifting apart on timers of
/// its own.
///
/// The interval is five minutes unless changed. A change takes effect at once:
/// the wait for the next beat restarts from the moment it was made.
@MainActor
@Observable
package final class RecalculationSignal {
    package static let defaultInterval: Duration = .seconds(5 * 60)

    package var interval: Duration {
        didSet {
            precondition(interval > .zero, "A recalculation interval must be positive")
            if interval != oldValue, beatTask != nil { schedule() }
        }
    }
    /// When the last beat went out. Nil before the first one.
    package private(set) var lastSignal: Date?

    private struct Subscriber {
        weak var owner: AnyObject?
        let handler: @MainActor () async -> Void
    }

    @ObservationIgnored private var subscribers: [Subscriber] = []
    @ObservationIgnored private var beatTask: Task<Void, Never>?

    package init(interval: Duration = RecalculationSignal.defaultInterval) {
        precondition(interval > .zero, "A recalculation interval must be positive")
        self.interval = interval
    }

    /// Runs `handler` on every beat for as long as `owner` is alive. The first
    /// subscriber starts the cadence.
    package func subscribe(_ owner: AnyObject, handler: @escaping @MainActor () async -> Void) {
        subscribers.append(Subscriber(owner: owner, handler: handler))
        if beatTask == nil { schedule() }
    }

    /// The last subscriber to leave stops the cadence.
    package func unsubscribe(_ owner: AnyObject) {
        subscribers.removeAll { $0.owner == nil || $0.owner === owner }
        if subscribers.isEmpty {
            beatTask?.cancel()
            beatTask = nil
        }
    }

    /// Sends a beat now, outside the cadence, and returns once every
    /// subscriber has handled it.
    package func send() async {
        subscribers.removeAll { $0.owner == nil }
        lastSignal = Date()
        for subscriber in subscribers where subscriber.owner != nil {
            await subscriber.handler()
        }
    }

    private func schedule() {
        beatTask?.cancel()
        let interval = interval
        beatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.send()
            }
        }
    }
}
