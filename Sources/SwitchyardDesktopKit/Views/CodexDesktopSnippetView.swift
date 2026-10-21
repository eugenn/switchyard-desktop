import AppKit
import SwiftUI

/// A block the user can paste into their own `~/.codex/config.toml` by hand,
/// so Codex Desktop can use this route too.
///
/// Desktop has no `--profile` of its own — it always reads the base
/// configuration directly — so the generated profile layer this app writes is
/// invisible to it. This is the only path that reaches Desktop, and copying it
/// is entirely the user's own edit to their own file: this app never writes
/// it, and never checks whether it was pasted anywhere.
package struct CodexDesktopSnippetView: View {
    package let model: WizardModel
    @Binding package var isExpanded: Bool
    @State private var copied = false

    package init(model: WizardModel, isExpanded: Binding<Bool>) {
        self.model = model
        self._isExpanded = isExpanded
    }

    package var body: some View {
        RouterDisclosurePanel(
            title: "Also use this route in Codex Desktop",
            subtitle: "· manual, optional",
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    """
                    Codex Desktop cannot select a profile, so it never sees the file Start \
                    writes. Paste this into your own \(model.codexConfigPath.path) instead, and \
                    it becomes your Codex default everywhere — Desktop, and any CLI session that \
                    does not choose a different profile. This app does not write this for you, \
                    and does not check whether you did.
                    """
                )
                .font(RouterTheme.sans(11))
                .foregroundStyle(RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)

                ScrollView([.horizontal, .vertical]) {
                    Text(highlightedSnippet)
                        .textSelection(.enabled)
                        .lineSpacing(2.5)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .background(RouterTheme.panel2, in: RoundedRectangle(cornerRadius: 10))

                HStack {
                    Spacer()
                    Button(copied ? "Snippet copied" : "Copy snippet") {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(snippet, forType: .string)
                    }
                    .buttonStyle(.routerSmall)
                }
            }
            .padding(12)
        }
    }

    private var snippet: String { model.manualDesktopSnippet }

    private var highlightedSnippet: AttributedString {
        TOMLHighlighter.highlight(snippet, font: RouterTheme.mono(10.5))
    }
}
