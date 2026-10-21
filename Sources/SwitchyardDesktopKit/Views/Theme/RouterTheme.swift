import SwiftUI

/// The dark palette and type scale the app's windows are drawn with.
///
/// Values come from the interface mockups in `mockups/`: a near-black window on
/// a darker ground, hairline separators tinted toward the ink color, and a
/// single green accent. The app forces a dark appearance, so these are absolute
/// colors rather than semantic ones.
package enum RouterTheme {
    package static let bg = Color(hex: 0x080A0A)
    package static let win = Color(hex: 0x0E1211)
    package static let rail = Color(hex: 0x0B0F0E)
    package static let panel = Color(hex: 0x121615)
    package static let panel2 = Color(hex: 0x181D1B)
    package static let sunk = Color(hex: 0x0A0D0C)

    package static let line = Color(hex: 0xE0F0E8, opacity: 0.075)
    package static let line2 = Color(hex: 0xE0F0E8, opacity: 0.15)
    package static let fill = Color(hex: 0xE0F0E8, opacity: 0.08)

    package static let ink = Color(hex: 0xE9F1EC)
    package static let ink2 = Color(hex: 0x9DADA6)
    package static let ink3 = Color(hex: 0x6D7D76)

    package static let accent = Color(hex: 0x4FC98A)
    package static let accentDim = Color(hex: 0x2FA96F)
    package static let warn = Color(hex: 0xFAB219)
    package static let crit = Color(hex: 0xD03B3B)
    package static let idle = Color(hex: 0x4E5854)

    package static let p50 = accent
    package static let p95 = Color(hex: 0x5598E7)
    package static let p99 = Color(hex: 0xD4B17D)
    package static let grid = Color(hex: 0x232827)
    package static let axis = Color(hex: 0x333A37)

    // MARK: - Type

    /// IBM Plex is not installed on a stock Mac, so the mockups' own fallbacks
    /// (the system sans and monospace faces) are what actually render.
    package static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    package static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    package static let body = sans(13)
    package static let bodySmall = sans(12.5)
    package static let caption = sans(11.5)
    package static let title = sans(19, .semibold)
}

package extension Color {
    package init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
