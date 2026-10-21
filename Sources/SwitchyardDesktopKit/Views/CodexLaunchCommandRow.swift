import AppKit
import SwiftUI

/// The command that puts a Codex session on the active route.
///
/// Routing is installed as a Codex profile layer, so a running proxy alone
/// changes nothing: the session has to ask for the profile. This row is shown
/// wherever the app reports a route as active, because the route is not usable
/// until the user starts Codex this way.
package struct CodexLaunchCommandRow: View {
    package var caption = """
        Start Codex like this to use the route. Sessions started without the flag keep your own \
        settings and are not routed.
        """
    @State private var copied = false

    package init(caption: String? = nil) {
        if let caption { self.caption = caption }
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(CodexLocations.launchCommand)
                    .font(RouterTheme.mono(11))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RouterTheme.accent.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                Button(copied ? "Command copied" : "Copy command") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(
                        CodexLocations.launchCommand, forType: .string
                    )
                }
                .buttonStyle(.routerSmall)
            }
            Text(caption)
                .font(RouterTheme.sans(11))
                .foregroundStyle(RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
