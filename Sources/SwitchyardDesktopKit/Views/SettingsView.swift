import SwiftUI

/// The app's Settings window (⌘,), shared by both editions.
package struct SettingsView: View {
    @Bindable private var model: WizardModel

    package init(model: WizardModel) {
        self.model = model
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Spend")
            RouterPanel {
                VStack(alignment: .leading, spacing: 8) {
                    LongContextToggle(model: model)
                    Text(
                        """
                        OpenAI bills a prompt over 272k tokens at twice the input rate and one \
                        and a half times the output rate. Turn this off and switchyard-desktop holds \
                        the window it advertises to Codex at 272k, so Codex compacts the \
                        conversation instead of sending a longer prompt.
                        """
                    )
                    .font(RouterTheme.caption)
                    .foregroundStyle(RouterTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    RouterDivider()
                    Text(model.contextWindowSummary)
                        .font(RouterTheme.caption)
                        .foregroundStyle(RouterTheme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.isApplied {
                        RouterNote(
                            systemImage: "arrow.clockwise",
                            text: "Routing is running. The change applies the next time you start routing.",
                            tint: RouterTheme.warn
                        )
                    }
                    if let error = model.preferencesError {
                        RouterNote(systemImage: "exclamationmark.triangle", text: error, tint: RouterTheme.crit)
                    }
                }
                .padding(12)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(RouterTheme.win)
        .foregroundStyle(RouterTheme.ink)
        .environment(\.colorScheme, .dark)
    }
}

/// The long-context switch, for the Settings window and for the main windows so
/// it can be changed where the route is being set up.
package struct LongContextToggle: View {
    @Bindable private var model: WizardModel
    private let title: String

    package init(model: WizardModel, title: String = "Allow long context (over 272k tokens)") {
        self.model = model
        self.title = title
    }

    package var body: some View {
        Toggle(isOn: $model.allowsLongContext) {
            Text(title)
                .font(RouterTheme.sans(12.5, .semibold))
                .foregroundStyle(RouterTheme.ink)
        }
        .toggleStyle(.checkbox)
        .help(
            "OpenAI bills prompts over 272k tokens at 2× input and 1.5× output. "
                + "Off: Codex compacts the conversation at 272k. Applies the next time routing starts."
        )
    }
}
