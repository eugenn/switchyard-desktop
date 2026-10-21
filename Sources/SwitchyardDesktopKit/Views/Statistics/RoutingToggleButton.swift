import SwiftUI

/// Where the route is, as the live bar's start control shows it. A start and a
/// stop are phases of their own, so the control animates the change instead of
/// greying out while it runs.
package enum RoutingPhase: Equatable {
    case idle, starting, running, stopping

    /// `held` is the phase a window keeps showing until its own animation has
    /// played out, even when the model finished sooner. Without one, a start or
    /// stop another window asked for still reads the right way round.
    package static func resolve(
        held: RoutingPhase?, isBusy: Bool, isStopping: Bool, isRouting: Bool
    ) -> RoutingPhase {
        if let held { return held }
        if isBusy { return isStopping ? .stopping : .starting }
        return isRouting ? .running : .idle
    }

    /// Only a settled route takes a click; a start or stop in flight finishes first.
    package var acceptsTap: Bool { self == .idle || self == .running }
}

/// One control that starts routing, shows it working, and stops it again.
///
/// It carries no label: the fork glyph says what it does. Idle it is the
/// primary action; while starting or stopping the glyph animates; once routing
/// it carries pulses, and turns red under the pointer to show it stops. Its
/// help text and accessibility label name the action.
package struct RoutingToggleButton: View {
    package let phase: RoutingPhase
    /// The model's current step, read out while a start or stop is in flight.
    package var stage: String?
    package let action: () -> Void

    @State private var isHovering = false
    @State private var phaseBegan = Date()

    package init(phase: RoutingPhase, stage: String?, action: @escaping () -> Void) {
        self.phase = phase
        self.stage = stage
        self.action = action
    }

    private var offersStop: Bool { phase == .running && isHovering }

    private static let width: CGFloat = 40

    package var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            RoutingForkGlyph(phase: phase, began: phaseBegan, ink: glyphInk)
                .frame(width: Self.width, height: 28)
                .background(background, in: shape)
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(PressScaleButtonStyle())
        .allowsHitTesting(phase.acceptsTap)
        .onHover { isHovering = $0 }
        .onChange(of: phase) { phaseBegan = Date() }
        .animation(.easeOut(duration: 0.3), value: phase)
        .animation(.easeOut(duration: 0.15), value: offersStop)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(stage ?? "")
    }

    private var help: String {
        switch phase {
        case .idle: "Start routing"
        case .starting: "Routing is starting"
        case .running: "Restores the captured Codex configuration, then stops the proxy."
        case .stopping: "Routing is stopping"
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .idle: "Start routing"
        case .starting: "Starting routing"
        case .running: "Stop routing"
        case .stopping: "Stopping routing"
        }
    }

    private var glyphInk: Color {
        phase == .idle ? Self.onAccent : RouterTheme.ink
    }

    private var background: Color {
        switch phase {
        case .idle: RouterTheme.accent
        case .starting, .stopping: RouterTheme.panel2
        case .running: offersStop ? RouterTheme.crit.opacity(0.1) : RouterTheme.accent.opacity(0.1)
        }
    }

    private var border: Color {
        switch phase {
        case .idle: .clear
        case .starting, .stopping: RouterTheme.line2
        case .running: offersStop ? RouterTheme.crit.opacity(0.55) : RouterTheme.accent.opacity(0.45)
        }
    }

    private static let onAccent = Color(hex: 0x04140C)
}

private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The app icon's one-input, three-output route, drawn so each phase can move
/// it: the branches draw out while starting, carry pulses toward their model
/// while routing, and pull back into the source while stopping.
///
/// Like the flow maps, it runs off the clock and draws into a canvas, so a
/// frame repaints a few strokes and never asks for layout.
private struct RoutingForkGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.routingWindowVisible) private var windowVisible

    let phase: RoutingPhase
    let began: Date
    let ink: Color

    /// The glyph is drawn in a 24-point grid and scaled to this.
    private static let side: CGFloat = 20
    private static let grid: CGFloat = 24

    /// The three models' colors, in the app icon's order.
    private static let nodeColors = [Color(hex: 0x33D6EE), Color(hex: 0xF9CB15), Color(hex: 0xFF7085)]

    private static let branches: [Path] = [
        branch(toY: 5),
        Path { path in
            path.move(to: CGPoint(x: 4, y: 12))
            path.addLine(to: CGPoint(x: 19, y: 12))
        },
        branch(toY: 19),
    ]

    private static func branch(toY y: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 4, y: 12))
            path.addLine(to: CGPoint(x: 8, y: 12))
            path.addCurve(
                to: CGPoint(x: 15, y: y),
                control1: CGPoint(x: 11.5, y: 12),
                control2: CGPoint(x: 11, y: y)
            )
            path.addLine(to: CGPoint(x: 19, y: y))
        }
    }

    var body: some View {
        let animates = !reduceMotion && windowVisible && phase != .idle
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates)) { context in
            let frame = Frame(phase: animates ? phase : .idle, elapsed: context.date.timeIntervalSince(began))
            Canvas { gc, size in
                draw(frame, in: &gc, size: size)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityHidden(true)
    }

    private func draw(_ frame: Frame, in gc: inout GraphicsContext, size: CGSize) {
        gc.scaleBy(x: size.width / Self.grid, y: size.height / Self.grid)
        let line = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)

        for (index, path) in Self.branches.enumerated() {
            let reach = frame.reach(index)
            if reach > 0 {
                gc.stroke(path.trimmedPath(from: 0, to: reach), with: .color(ink.opacity(frame.lineOpacity)), style: line)
            }
            if let pulse = frame.pulse(index) {
                gc.stroke(
                    path.trimmedPath(from: pulse, to: min(pulse + 0.14, 1)),
                    with: .color(Self.nodeColors[index]),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
            }
        }

        gc.fill(Self.circle(x: 4, y: 12, radius: 2.3), with: .color(ink))

        for index in Self.branches.indices {
            let scale = frame.nodeScale(index)
            guard scale > 0.01 else { continue }
            let y: CGFloat = [5, 12, 19][index]
            let node = Self.circle(x: 19.5, y: y, radius: 2.4 * scale)
            gc.fill(node, with: .color(Self.nodeColors[index]))
            gc.stroke(node, with: .color(ink), lineWidth: 1.2 * scale)
        }
    }

    private static func circle(x: CGFloat, y: CGFloat, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    /// Where each branch, pulse and node is `elapsed` seconds into a phase.
    private struct Frame {
        let phase: RoutingPhase
        let elapsed: Double

        /// One draw-out of all three branches while starting, repeated.
        private static let startCycle = 1.1
        /// How long a pulse takes to run a branch while routing.
        private static let pulseCycle = 1.3
        /// Branches draw out one after another, top first.
        private static let stagger = [0.0, 0.12, 0.24]
        /// On a stop the middle model goes first, then the bottom, then the top.
        private static let stopStagger = [0.2, 0.0, 0.1]

        var lineOpacity: Double { phase == .running ? 0.5 : 1 }

        func reach(_ index: Int) -> Double {
            switch phase {
            case .idle, .running:
                return 1
            case .starting:
                let local = startLocal(index)
                return easeOut(min(local / 0.55, 1))
            case .stopping:
                let progress = min(elapsed / 0.9, 1)
                return 1 - progress * progress
            }
        }

        func pulse(_ index: Int) -> Double? {
            guard phase == .running else { return nil }
            let cycle = fraction(elapsed / Self.pulseCycle + Double(index) / 3)
            return cycle * 0.86
        }

        func nodeScale(_ index: Int) -> Double {
            switch phase {
            case .idle:
                return 1
            case .starting:
                // Hidden until its branch arrives, then a pop past full size.
                let local = startLocal(index)
                if local < 0.45 { return 0 }
                if local < 0.65 { return 1.35 * (local - 0.45) / 0.2 }
                return 1.35 - 0.35 * (local - 0.65) / 0.35
            case .running:
                let breath = 0.5 - 0.5 * cos(fraction((elapsed + Double(index) * 0.2) / Self.pulseCycle) * 2 * .pi)
                return 1 + 0.2 * breath
            case .stopping:
                let shrink = max(0, elapsed - Self.stopStagger[index]) / 0.5
                return max(0, 1 - shrink)
            }
        }

        private func startLocal(_ index: Int) -> Double {
            let shifted = elapsed - Self.stagger[index]
            guard shifted > 0 else { return 0 }
            return fraction(shifted / Self.startCycle)
        }

        private func fraction(_ value: Double) -> Double {
            value - value.rounded(.down)
        }

        private func easeOut(_ value: Double) -> Double {
            1 - pow(1 - value, 3)
        }
    }
}
