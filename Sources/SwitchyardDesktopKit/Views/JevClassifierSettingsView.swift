import SwiftUI

package struct JevClassifierSettingsView: View {
    @Bindable private var model: WizardModel

    package init(model: WizardModel) { self.model = model }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Jev model ID", text: Binding(
                get: { model.profile.jevClassifier?.modelID ?? "jev-latest" },
                set: { model.profile.jevClassifier?.modelID = $0 }
            ))
            if model.profile.algorithm != .llmClassifier {
                HStack {
                    Text("Capable probability cutoff")
                    TextField("Cutoff", value: Binding(
                        get: { model.profile.jevClassifier?.cutoff ?? 0.6 },
                        set: { model.profile.jevClassifier?.cutoff = $0 }
                    ), format: .number)
                    .frame(width: 75)
                }
                Text("Selects Capable when its probability is above the cutoff (0 to 1); otherwise Efficient.")
                    .foregroundStyle(RouterTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Optional decision instructions (blank uses server defaults)", text: Binding(
                get: { model.profile.jevClassifier?.instructions ?? "" },
                set: { model.profile.jevClassifier?.instructions = $0 }
            ), axis: .vertical)
            .lineLimit(3...6)
            Text(model.profile.algorithm == .llmClassifier
                 ? "Jev selects one of your target roles using their descriptions. The default target handles decision failures. LLM prompts and reasoning settings do not apply."
                 : "Instructions must preserve capable = Capable and efficient = Efficient. LLM classifier prompts and reasoning settings do not apply to Jev.")
                .foregroundStyle(RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if model.profile.nativeRouteOptions != nil {
                Text("This setup has custom route options. Review them before restoring the preset to enable Jev.")
                    .foregroundStyle(RouterTheme.warn)
                Button("Restore native preset") { model.profile.nativeRouteOptions = nil }
            }
            JevAPIKeyEditor(model: model)
        }
        .textFieldStyle(.roundedBorder)
        .font(RouterTheme.caption)
    }
}

package struct JevAPIKeyEditor: View {
    @Bindable private var model: WizardModel
    @State private var keyInput = ""

    package init(model: WizardModel) { self.model = model }

    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TypeSafe API key")
                .font(RouterTheme.sans(12, .semibold))
            SecureField(model.hasJevAPIKey ? "Replace saved key" : "Paste your TypeSafe API key", text: $keyInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack {
                Button("Save in Keychain") { save() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.hasJevAPIKey {
                    Text("Saved")
                        .foregroundStyle(RouterTheme.ink2)
                    Button("Remove key") { model.removeJevAPIKey() }
                }
            }
            Text("Stored in macOS Keychain, never in routing profiles or TOML. Jev sends conversation context to TypeSafe for a separately billed routing decision. Changes apply on the next routing start.")
                .font(RouterTheme.caption)
                .foregroundStyle(RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.jevAPIKeyError {
                Text(error).foregroundStyle(RouterTheme.crit)
            }
        }
        .onAppear { model.refreshJevAPIKeyStatus() }
        .onDisappear { keyInput = "" }
        .disabled(model.isBusy)
    }

    private func save() {
        if model.saveJevAPIKey(keyInput) { keyInput = "" }
    }
}
