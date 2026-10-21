import AppKit
import SwiftUI

/// Panel with the statistics window's own header row.
package struct StatsPanel<Content: View>: View {
    package let title: String
    package var note: String?
    package var accessory: AnyView?
    @ViewBuilder var content: Content

    package init(
        title: String,
        note: String? = nil,
        accessory: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.note = note
        self.accessory = accessory
        self.content = content()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(RouterTheme.sans(12.5, .semibold))
                    .foregroundStyle(RouterTheme.ink)
                if let note {
                    Text(note)
                        .font(RouterTheme.mono(10))
                        .foregroundStyle(RouterTheme.ink3)
                }
                Spacer(minLength: 4)
                if let accessory { accessory }
            }
            content
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RouterTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(RouterTheme.line, lineWidth: 1)
        )
    }
}

/// Narrows a pane to one client conversation. Sessions come from the log's
/// bounded tail, so the list is only ever what is still on disk, and each is
/// named the way Codex names it. Conversations that routed a call recently
/// carry a green dot: several can be live at once. Before the first one has
/// routed a call, it holds a placeholder rather than naming a conversation.
package struct SessionPicker: View {
    package let sessions: [RoutingSession]
    @Binding var selection: String?
    package var activeSessionIDs: Set<String> = []
    /// Offers "All sessions". Without it, no selection means the newest
    /// session, which is what the flow map then shows.
    package var allowsAll = true

    package static let liveColor = Color(hex: 0x0CA30C)

    /// Menu items are drawn by AppKit, which tints a template image; a plain
    /// bitmap keeps the dot green. The clear one keeps titles aligned.
    private static let liveDot = dot(NSColor(liveColor))
    private static let noDot = dot(.clear)

    private static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private var shown: RoutingSession? {
        if let selection, let session = sessions.first(where: { $0.id == selection }) { return session }
        return allowsAll ? nil : sessions.first
    }

    private var shownIsLive: Bool {
        shown.map { activeSessionIDs.contains($0.id) } ?? false
    }

    private var pickerSelection: Binding<String?> {
        Binding(get: { shown?.id }, set: { selection = $0 })
    }

    package var body: some View {
        if sessions.isEmpty {
            waiting
        } else {
            menu
        }
    }

    /// Nothing to pick yet: the run has not routed a conversation.
    private var waiting: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 9))
            Text("Waiting for a session")
                .font(RouterTheme.sans(11.5))
                .lineLimit(1)
        }
        .foregroundStyle(RouterTheme.ink3)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(RouterTheme.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
        .fixedSize()
        .help("The first Codex conversation routed through this run is picked here.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session filter, waiting for the first session")
    }

    private var menu: some View {
        Menu {
            if allowsAll {
                Button("All sessions") { selection = nil }
                Divider()
            }
            Picker("Session", selection: pickerSelection) {
                ForEach(sessions) { session in
                    let isLive = activeSessionIDs.contains(session.id)
                    Label {
                        Text("\(session.title)  —  \(isLive ? "active · " : "")\(session.detail)")
                    } icon: {
                        Image(nsImage: isLive ? Self.liveDot : Self.noDot)
                    }
                    .tag(Optional(session.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                if shownIsLive {
                    Circle()
                        .fill(Self.liveColor)
                        .frame(width: 6, height: 6)
                } else {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 9))
                }
                Text(shown?.shortTitle ?? "All sessions")
                    .font(RouterTheme.sans(11.5, shown == nil ? .regular : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(RouterTheme.ink3)
            }
            .foregroundStyle(shown == nil ? RouterTheme.ink2 : RouterTheme.ink)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                shown == nil ? RouterTheme.panel : RouterTheme.accent.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(shown == nil ? RouterTheme.line : RouterTheme.accent, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel(
            "Session filter, \(shown?.title ?? "all sessions")\(shownIsLive ? ", active" : "")"
        )
    }

    private var helpText: String {
        let live = activeSessionIDs.intersection(sessions.map(\.id)).count
        let base = "Show only the turns one client conversation routed."
        guard live > 0 else { return base }
        return "\(base) \(live) active in the last 15 minutes, marked with a green dot."
    }
}

/// One of the headline numbers across the top of the statistics pane.
package struct KPITile: View {
    package let label: String
    package let value: String
    package var unit: String?
    package var subtitle: String?
    package var highlight: String?
    package var sparkline: [Double] = []
    package var sparkTint: Color = RouterTheme.accentDim

    package var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(RouterTheme.mono(9.5, .medium))
                .tracking(0.85)
                .foregroundStyle(RouterTheme.ink3)

            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(RouterTheme.sans(21, .semibold))
                        .foregroundStyle(RouterTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let unit {
                        Text(unit)
                            .font(RouterTheme.sans(12, .medium))
                            .foregroundStyle(RouterTheme.ink2)
                            .fixedSize()
                    }
                }
                Spacer(minLength: 0)
                if sparkline.count > 1 {
                    Sparkline(values: sparkline, tint: sparkTint)
                        .frame(width: 60, height: 18)
                        .padding(.bottom, 3)
                }
            }

            if subtitle != nil || highlight != nil {
                HStack(spacing: 4) {
                    if let subtitle {
                        Text(subtitle)
                            .font(RouterTheme.mono(10))
                            .foregroundStyle(RouterTheme.ink2)
                    }
                    if let highlight {
                        Text(highlight)
                            .font(RouterTheme.mono(10))
                            .foregroundStyle(RouterTheme.accent)
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact trend line for a KPI tile.
package struct Sparkline: View {
    package let values: [Double]
    package var tint: Color

    package var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let maximum = values.max() ?? 0
            let minimum = values.min() ?? 0
            let span = max(maximum - minimum, 0.000001)
            let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : size.width

            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) * step,
                    y: size.height - CGFloat((value - minimum) / span) * (size.height - 4) - 2
                )
            }

            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

                if let last = points.last {
                    Circle()
                        .fill(tint)
                        .frame(width: 4.4, height: 4.4)
                        .position(last)
                }
            }
        }
    }
}

/// Horizontal share bar with its own percentage, used by Route share.
package struct ShareBar: View {
    package let title: String
    package let percentage: Double
    package var detail: String?
    package var isIdle: Bool

    package var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(RouterTheme.sans(12))
                    .foregroundStyle(isIdle ? RouterTheme.ink3 : RouterTheme.ink)
                if isIdle {
                    RouterTag(text: "idle")
                }
                Spacer(minLength: 6)
                Text(percentage.formatted(.percent.precision(.fractionLength(1))))
                    .font(RouterTheme.mono(11))
                    .foregroundStyle(isIdle ? RouterTheme.ink3 : RouterTheme.ink)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: 0xE0F0E8, opacity: 0.06))
                    if percentage > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(RouterTheme.accentDim)
                            .frame(width: max(geometry.size.width * percentage, 2))
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .help(detail ?? title)
    }
}

/// Small serving/idle indicator used in the targets table.
package struct StateBadge: View {
    package let text: String
    package let isActive: Bool

    package var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isActive ? Color(hex: 0x0CA30C) : Color(hex: 0x3C4442))
                .frame(width: 5, height: 5)
            Text(text)
                .font(RouterTheme.mono(10))
                .foregroundStyle(isActive ? RouterTheme.ink2 : RouterTheme.ink3)
        }
    }
}

package struct StatsEmptyState: View {
    package let message: String
    package var systemImage = "chart.line.downtrend.xyaxis"

    package var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(RouterTheme.ink3)
            Text(message)
                .font(RouterTheme.bodySmall)
                .foregroundStyle(RouterTheme.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
