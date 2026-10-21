import SwiftUI

// MARK: - Containers

/// The bordered, slightly lifted surface every grouped list and card uses.
package struct RouterPanel<Content: View>: View {
    package var background: Color = RouterTheme.panel
    package var radius: CGFloat = 8
    package var border: Color = RouterTheme.line
    @ViewBuilder package var content: Content

    package init(
        background: Color = RouterTheme.panel, radius: CGFloat = 8, border: Color = RouterTheme.line,
        @ViewBuilder content: () -> Content
    ) {
        self.background = background
        self.radius = radius
        self.border = border
        self.content = content()
    }

    package var body: some View {
        content
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}

/// Mono, letter-spaced, uppercase section label — `h2` in the mockups.
package struct SectionLabel: View {
    package let text: String
    package var trailing: String?

    package init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    package var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(text.uppercased())
                .font(RouterTheme.mono(10, .medium))
                .tracking(0.9)
                .foregroundStyle(RouterTheme.ink3)
            if let trailing {
                Text(trailing)
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.ink3)
            }
        }
    }
}

/// Hairline separator matching `--line`.
package struct RouterDivider: View {
    package var color: Color = RouterTheme.line

    package init(color: Color = RouterTheme.line) {
        self.color = color
    }

    package var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// A panel whose content is folded away until it is asked for. Every expert
/// detail in the app uses this one control, so "there is more here" always
/// looks the same.
package struct RouterDisclosurePanel<Content: View>: View {
    package let title: String
    package var subtitle: String?
    package var glyph: RouterCheckGlyph.Kind?
    package var background: Color = RouterTheme.panel
    @Binding package var isExpanded: Bool
    @ViewBuilder package var content: Content

    package init(
        title: String, subtitle: String? = nil, glyph: RouterCheckGlyph.Kind? = nil,
        background: Color = RouterTheme.panel, isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.glyph = glyph
        self.background = background
        self._isExpanded = isExpanded
        self.content = content()
    }

    package var body: some View {
        RouterPanel(background: background) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        if let glyph {
                            RouterCheckGlyph(kind: glyph, size: 12)
                        }
                        Text(title)
                            .font(RouterTheme.sans(12.5, .medium))
                            .foregroundStyle(RouterTheme.ink)
                        if let subtitle {
                            Text(subtitle)
                                .font(RouterTheme.mono(10))
                                .foregroundStyle(RouterTheme.ink3)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(RouterTheme.ink3)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isExpanded ? [.isSelected] : [])

                if isExpanded {
                    RouterDivider()
                    content
                }
            }
        }
    }
}

// MARK: - Buttons

package struct RouterButtonStyle: ButtonStyle {
    package enum Kind { case normal, primary, ghost }

    package var kind: Kind = .normal
    package var small = false
    @Environment(\.isEnabled) private var isEnabled

    package func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = small ? 22 : 26
        return configuration.label
            .font(RouterTheme.sans(small ? 11.5 : 12.5, kind == .primary ? .medium : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 9 : 12)
            .frame(height: height)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(kind == .primary ? .clear : RouterTheme.line2, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: Color(hex: 0x04140C)
        case .normal: RouterTheme.ink
        case .ghost: RouterTheme.ink2
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? RouterTheme.accentDim : RouterTheme.accent
        case .normal: pressed ? RouterTheme.line2 : RouterTheme.panel2
        case .ghost: pressed ? RouterTheme.fill : .clear
        }
    }
}

package extension ButtonStyle where Self == RouterButtonStyle {
    package static var router: RouterButtonStyle { RouterButtonStyle() }
    package static var routerPrimary: RouterButtonStyle { RouterButtonStyle(kind: .primary) }
    package static var routerSmall: RouterButtonStyle { RouterButtonStyle(small: true) }
    package static var routerGhost: RouterButtonStyle { RouterButtonStyle(kind: .ghost, small: true) }
}

/// Full-width menu control used wherever a model or target is chosen. A plain
/// `Picker` centers its popup button inside the space it is given, which leaves
/// the value floating in the middle of a card; this keeps the current value on
/// the leading edge and the control the width of its row.
package struct RouterMenu<Content: View>: View {
    package let value: String
    package var placeholder = false
    package var tint: Color?
    @ViewBuilder package var content: Content

    package init(
        value: String, placeholder: Bool = false, tint: Color? = nil, @ViewBuilder content: () -> Content
    ) {
        self.value = value
        self.placeholder = placeholder
        self.tint = tint
        self.content = content()
    }

    package var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 8) {
                Text(value)
                    .font(RouterTheme.sans(12.5))
                    .foregroundStyle(tint ?? (placeholder ? RouterTheme.ink3 : RouterTheme.ink))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(RouterTheme.ink3)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RouterTheme.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(RouterTheme.line2))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Small parts

/// Bordered mono chip — `default`, `codex default`, `idle`.
package struct RouterTag: View {
    package let text: String
    package var tint: Color = RouterTheme.ink3

    package init(text: String, tint: Color = RouterTheme.ink3) {
        self.text = text
        self.tint = tint
    }

    package var body: some View {
        Text(text.uppercased())
            .font(RouterTheme.mono(9, .medium))
            .tracking(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
    }
}

/// Filled role flag — `classifier`, `fallback`.
package struct RouterFlag: View {
    package let text: String
    package var tint: Color = RouterTheme.accent

    package init(text: String, tint: Color = RouterTheme.accent) {
        self.text = text
        self.tint = tint
    }

    package var body: some View {
        Text(text)
            .font(RouterTheme.mono(9, .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Status pill dot used by the proxy indicators.
package struct RouterDot: View {
    package var color: Color
    package var size: CGFloat = 7
    package var halo = false

    package init(color: Color, size: CGFloat = 7, halo: Bool = false) {
        self.color = color
        self.size = size
        self.halo = halo
    }

    package var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(color.opacity(halo ? 0.28 : 0), lineWidth: 3)
                    .padding(-3)
            )
    }
}

/// The check / cross / dash / spinner glyph column shared by preflight and
/// prerequisite rows.
package struct RouterCheckGlyph: View {
    package enum Kind { case ok, fail, idle, working, warn }

    package let kind: Kind
    package var size: CGFloat = 13

    package init(kind: Kind, size: CGFloat = 13) {
        self.kind = kind
        self.size = size
    }

    package var body: some View {
        switch kind {
        case .ok:
            symbol("checkmark", RouterTheme.accent)
        case .fail:
            symbol("xmark", RouterTheme.crit)
        case .warn:
            symbol("exclamationmark.triangle", RouterTheme.warn)
        case .idle:
            symbol("minus", RouterTheme.idle)
        case .working:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: size + 3, height: size + 3)
        }
    }

    private func symbol(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size + 3, height: size + 3)
    }
}

/// Footnote with a leading SF Symbol, as used for the privacy and refresh notes.
package struct RouterNote: View {
    package let systemImage: String
    package let text: String
    package var tint: Color = RouterTheme.ink3

    package init(systemImage: String, text: String, tint: Color = RouterTheme.ink3) {
        self.systemImage = systemImage
        self.text = text
        self.tint = tint
    }

    package var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(RouterTheme.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The inline "fix this first" callout on the setup step.
package struct RouterCallout: View {
    package let title: String
    package let message: String
    package var tint: Color = RouterTheme.crit
    package var systemImage: String = "exclamationmark.circle"

    package init(
        title: String, message: String, tint: Color = RouterTheme.crit,
        systemImage: String = "exclamationmark.circle"
    ) {
        self.title = title
        self.message = message
        self.tint = tint
        self.systemImage = systemImage
    }

    package var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(RouterTheme.sans(12.5, .semibold))
                    .foregroundStyle(RouterTheme.ink)
                Text(message)
                    .font(RouterTheme.caption)
                    .foregroundStyle(RouterTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.3), lineWidth: 1)
        )
    }
}

/// Mono segmented control (time range, request filter).
package struct RouterSegments<Value: Hashable>: View {
    package let values: [Value]
    package let label: (Value) -> String
    @Binding var selection: Value

    package var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                let selected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(label(value))
                        .font(RouterTheme.mono(10.5, selected ? .medium : .regular))
                        .foregroundStyle(selected ? RouterTheme.ink : RouterTheme.ink3)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(selected ? RouterTheme.fill : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RouterTheme.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(RouterTheme.line, lineWidth: 1)
        )
    }
}

/// Key/value line used by the review profile panel and the request detail pane.
package struct RouterKeyValue: View {
    package let key: String
    package let value: String
    package var flag: (text: String, tint: Color)?
    package var monospaced = true

    package init(key: String, value: String, flag: (text: String, tint: Color)? = nil, monospaced: Bool = true) {
        self.key = key
        self.value = value
        self.flag = flag
        self.monospaced = monospaced
    }

    package var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(key)
                .font(RouterTheme.bodySmall)
                .foregroundStyle(RouterTheme.ink2)
            if let flag {
                RouterFlag(text: flag.text, tint: flag.tint)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? RouterTheme.mono(11.5) : RouterTheme.bodySmall)
                .foregroundStyle(RouterTheme.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// Step heading pair shared by every wizard step.
package struct RouterStepHeader: View {
    package let title: String
    package let subtitle: String

    package var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(RouterTheme.title)
                .foregroundStyle(RouterTheme.ink)
            Text(subtitle)
                .font(RouterTheme.bodySmall)
                .foregroundStyle(RouterTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
