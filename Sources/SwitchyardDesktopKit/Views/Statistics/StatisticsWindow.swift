import SwiftUI

/// The routing window: a left icon rail that switches between Overview,
/// Statistics and Requests, all reading the live proxy and its durable routing
/// log. The window is a fixed size, so every pane is laid out for exactly this
/// much room.
package struct StatisticsWindow: View {
    @Bindable package var monitor: RoutingMonitor
    /// The phase the start control keeps showing until its animation has
    /// played out, however quickly the model finished.
    @State private var heldPhase: RoutingPhase?
    @State private var failureTitle = ""
    @State private var failureMessage = ""
    @State private var showsFailure = false
    /// Reopens the setup wizard for `Routing config`.
    package var openSetup: (() -> Void)?
    package var showsStartControl: Bool

    /// The one size the window ever has; each app's own scene pins to it.
    package static let windowWidth: CGFloat = 1_080
    package static let windowHeight: CGFloat = 700

    package init(
        monitor: RoutingMonitor,
        openSetup: (() -> Void)? = nil,
        showsStartControl: Bool = false
    ) {
        self.monitor = monitor
        self.openSetup = openSetup
        self.showsStartControl = showsStartControl
    }

    package var body: some View {
        VStack(spacing: 0) {
            liveBar
            RouterDivider()

            HStack(alignment: .top, spacing: 0) {
                rail
                    .frame(width: 48)
                Rectangle()
                    .fill(RouterTheme.line)
                    .frame(width: 1)

                Group {
                    switch monitor.pane {
                    case .overview:
                        OverviewPane(monitor: monitor, openSetup: openSetup)
                    case .statistics:
                        StatisticsPane(monitor: monitor)
                    case .requests:
                        RequestsPane(monitor: monitor)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(RouterTheme.win)
        .environment(\.colorScheme, .dark)
        .frame(width: Self.windowWidth, height: Self.windowHeight)
        .task {
            monitor.beginPolling()
        }
        .observeRoutingWindowVisibility { monitor.setWindowVisible($0) }
        .onDisappear {
            monitor.endPolling()
        }
        // A new run empties the window at once rather than on the next poll.
        .onChange(of: monitor.model.routingStartedAt) {
            monitor.followRoutingRun()
        }
        .alert(failureTitle, isPresented: $showsFailure) {
            if let openSetup {
                Button("Open configuration", action: openSetup)
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(failureMessage)
        }
    }

    // MARK: - Live bar

    private var liveBar: some View {
        HStack(spacing: 8) {
            RouterDot(
                color: monitor.isRouting ? RouterTheme.accent : RouterTheme.idle,
                halo: monitor.isRouting
            )
            Text(monitor.isRouting ? "Routing on" : "Routing off")
                .font(RouterTheme.sans(11.5, .medium))
                .foregroundStyle(monitor.isRouting ? RouterTheme.ink : RouterTheme.ink2)

            if let lastRefresh = monitor.lastRefresh {
                Text("· updated \(lastRefresh.formatted(date: .omitted, time: .standard))")
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.ink3)
            }

            Spacer(minLength: 10)

            if let statsError = monitor.statsError {
                Text(statsError)
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.warn)
                    .lineLimit(1)
            }

            RefreshButton(monitor: monitor)

            if showsStartControl {
                RoutingToggleButton(
                    phase: routingPhase,
                    stage: monitor.model.applyState.workingMessage
                ) {
                    Task { await toggleRouting() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var routingPhase: RoutingPhase {
        let model = monitor.model
        return .resolve(
            held: heldPhase,
            isBusy: model.isBusy,
            isStopping: model.isStopping,
            isRouting: monitor.isRouting || model.isApplied
        )
    }

    /// Long enough for one full draw-out of the start glyph.
    private static let minimumStart = Duration.milliseconds(1_200)
    /// Long enough for the branches to pull all the way back in.
    private static let minimumStop = Duration.milliseconds(1_000)

    private func toggleRouting() async {
        switch routingPhase {
        case .idle: await startRouting()
        case .running: await stopRouting()
        case .starting, .stopping: return
        }
    }

    private func startRouting() async {
        guard heldPhase == nil else { return }
        heldPhase = .starting
        let began = ContinuousClock.now
        let model = monitor.model
        await model.discoverSubscriptionModelsIfNeeded()
        await model.apply()
        await Self.hold(since: began, for: Self.minimumStart)
        heldPhase = nil
        if case .failed(let message) = model.applyState {
            report("Could not start routing", message)
        }
    }

    private func stopRouting() async {
        guard heldPhase == nil else { return }
        heldPhase = .stopping
        let began = ContinuousClock.now
        let model = monitor.model
        let stopped = await model.revert()
        await Self.hold(since: began, for: Self.minimumStop)
        heldPhase = nil
        if case .failed(let message) = model.applyState {
            report(stopped ? "Routing stopped with a warning" : "Could not stop routing", message)
        }
    }

    private static func hold(since began: ContinuousClock.Instant, for minimum: Duration) async {
        let remaining = minimum - (ContinuousClock.now - began)
        if remaining > .zero {
            try? await Task.sleep(for: remaining)
        }
    }

    private func report(_ title: String, _ message: String) {
        failureTitle = title
        failureMessage = message
        showsFailure = true
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(spacing: 2) {
            ForEach(RoutingMonitor.Pane.allCases) { pane in
                railItem(
                    title: pane.title,
                    symbol: pane.symbol,
                    isSelected: monitor.pane == pane
                ) {
                    monitor.pane = pane
                }
            }

            Spacer(minLength: 8)

            if let openSetup {
                RouterDivider()
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                railItem(title: "Routing config", symbol: "gearshape", isSelected: false) {
                    openSetup()
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RouterTheme.rail)
    }

    /// Icon-only rail button: the name lives in the tooltip and in the
    /// accessibility label so the rail stays one narrow column.
    private func railItem(
        title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? RouterTheme.accent : RouterTheme.ink2)
                .frame(width: 36, height: 30)
                .background(
                    isSelected ? RouterTheme.accent.opacity(0.11) : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Re-reads the log and the proxy on demand. The arrow turns a whole turn per
/// tap, and keeps turning while a slow read is still out, so a refresh that
/// finishes at once still reads as having happened.
///
/// Background polls leave it alone: it only moves for the refresh it was
/// asked for, and stays at full strength while one runs behind it.
private struct RefreshButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let monitor: RoutingMonitor
    @State private var turns: Double = 0
    @State private var isSpinning = false

    private static let turn = Duration.milliseconds(700)

    var body: some View {
        Button {
            Task { await refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(turns * 360))
        }
        .buttonStyle(LiveBarIconButtonStyle())
        .allowsHitTesting(!isSpinning)
        .help("Refresh statistics")
        .accessibilityLabel(isSpinning ? "Refreshing statistics" : "Refresh statistics")
    }

    private func refresh() async {
        guard !isSpinning else { return }
        isSpinning = true
        defer { isSpinning = false }
        let work = Task { await monitor.refresh() }
        if reduceMotion {
            await work.value
            return
        }
        repeat {
            withAnimation(.easeInOut(duration: 0.7)) { turns += 1 }
            try? await Task.sleep(for: Self.turn)
        } while monitor.isRefreshing
        await work.value
    }
}

private struct LiveBarIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(RouterTheme.ink)
            .frame(width: 30, height: 28)
            .background(configuration.isPressed ? RouterTheme.line2 : RouterTheme.panel2, in: shape)
            .overlay(shape.strokeBorder(RouterTheme.line2, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }
}

/// Pane heading: eyebrow, title, and whatever controls the pane owns.
package struct PaneHeader<Trailing: View>: View {
    package let eyebrow: String
    package let title: String
    @ViewBuilder var trailing: Trailing

    package var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow.uppercased())
                    .font(RouterTheme.mono(9.5, .medium))
                    .tracking(0.85)
                    .foregroundStyle(RouterTheme.ink3)
                Text(title)
                    .font(RouterTheme.sans(19, .semibold))
                    .foregroundStyle(RouterTheme.ink)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) { trailing }
        }
    }
}
