import SwiftUI

struct ModelSettingsCard: View {
    @Bindable var workspace: IntelligenceWorkspace
    @State private var key = ""
    var body: some View {
        SleepCard(title: "Your intelligence", eyebrow: "PRIVATE BY DEFAULT") {
            SleepFormField(title: "Provider") {
                Picker("Provider", selection: $workspace.provider) {
                    ForEach(IntelligenceProvider.allCases) { provider in Text(provider.title).tag(provider) }
                }.pickerStyle(.menu).labelsHidden()
            }
            if workspace.provider == .apple {
                Text(AppleIntelligenceClient.availability).sleepText(.small)
                Text("Apple’s model handles a compact summary on this device. Choose a cloud model for a more detailed interpretation. Switching never sends data automatically.")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            } else {
                if workspace.provider.needsKey {
                    Text(workspace.keySaved ? "API key saved in this device’s Keychain" : "Add your own API key").sleepText(.small)
                    SleepFormField(title: workspace.keySaved ? "Replace API key" : "API key") {
                        SecureField("Paste API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    }
                    HStack {
                        Button("Save key", action: saveKey).disabled(key.isEmpty).buttonStyle(SleepButtonStyle())
                        if workspace.keySaved { Button("Remove key", action: workspace.removeKey).buttonStyle(SleepButtonStyle(kind: .text)) }
                    }
                    Text("Requests go directly to \(workspace.provider.title). Keys stay on this iPhone and are never sent to your Pod or Replit. Your provider bills your API account.")
                        .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                } else {
                    SleepFormField(title: "Your Ollama server") {
                        TextField("http://my-mac.local:11434", text: $workspace.localAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }
                    Text("Run Gemma or another installed model on your own computer. This option sends the report summary to that server; it does not run Gemma on the iPhone.")
                        .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                }
                SleepFormField(title: "Model") {
                    Picker("Model", selection: $workspace.modelID) {
                        ForEach(workspace.choices, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu).labelsHidden()
                }
                SleepFormField(title: "API model ID · editable") {
                    TextField("Model ID", text: $workspace.modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("Refresh available models") { Task { await workspace.refreshModels() } }.buttonStyle(SleepButtonStyle())
            }
            Button("Test model connection") { Task { await workspace.testModel() } }
                .buttonStyle(SleepButtonStyle(kind: .primary)).disabled(!workspace.ready || AppMode.isDemo)
            Text("The test sends only a short test prompt. Cloud tests may incur a small API charge. A saved key is not proof of model access.")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            if workspace.provider.needsKey {
                Stepper("Monthly request limit on this device: \(workspace.monthlyLimit)", value: $workspace.monthlyLimit, in: 0...1000, step: 25)
                Text("\(workspace.attempts) attempts this UTC month. Includes tests and failures. This is separate from the Pod coach’s usage limit and is not a dollar budget.")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            }
        }.disabled(workspace.busy)
            .onChange(of: workspace.provider) { key = ""; workspace.checkKey() }
            .onDisappear { key = "" }
    }
    private func saveKey() { workspace.saveKey(key); key = "" }
}
