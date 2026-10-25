import SwiftUI

struct ModelSettingsCard: View {
    @Bindable var workspace: IntelligenceWorkspace
    @State private var key = ""
    var body: some View {
        FeatureSection(title: "Model connection", eyebrow: "PRIVATE BY DEFAULT") {
            FeatureField(title: "Provider") {
                Picker("Provider", selection: $workspace.provider) {
                    ForEach(IntelligenceProvider.allCases) { provider in Text(provider.title).tag(provider) }
                }.pickerStyle(.menu).labelsHidden()
            }
            if workspace.provider == .apple {
                Text(AppleIntelligenceClient.availability).font(.subheadline)
                Text("Apple’s model handles a compact summary on this device. Choose a cloud model for a more detailed interpretation. Switching never sends data automatically.")
                    .font(.caption).foregroundStyle(Theme.text2)
            } else {
                if workspace.provider.needsKey {
                    Text(workspace.keySaved ? "API key saved in this device’s Keychain" : "Add your own API key").font(.subheadline)
                    FeatureField(title: workspace.keySaved ? "Replace API key" : "API key") {
                        SecureField("Paste API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    }
                    HStack {
                        Button("Save key", action: saveKey).disabled(key.isEmpty).buttonStyle(GlassButtonStyle())
                        if workspace.keySaved { Button("Remove key", action: workspace.removeKey).buttonStyle(GlassButtonStyle()) }
                    }
                    Text("Requests go directly to \(workspace.provider.title). Keys stay on this iPhone and are never sent to your Pod or Replit. Your provider bills your API account.")
                        .font(.caption).foregroundStyle(Theme.text2)
                } else {
                    FeatureField(title: "Your Ollama server") {
                        TextField("http://my-mac.local:11434", text: $workspace.localAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    }
                    Text("Run Gemma or another installed model on your own computer. This option sends the report summary to that server; it does not run Gemma on the iPhone.")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
                FeatureField(title: "Model") {
                    Picker("Model", selection: $workspace.modelID) {
                        ForEach(workspace.choices, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu).labelsHidden()
                }
                FeatureField(title: "API model ID · editable") {
                    TextField("Model ID", text: $workspace.modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("Refresh available models") { Task { await workspace.refreshModels() } }.buttonStyle(GlassButtonStyle())
            }
            Button("Test model connection") { Task { await workspace.testModel() } }
                .buttonStyle(PrimaryButtonStyle()).disabled(!workspace.ready || AppMode.isDemo)
            Text("The test sends only a short test prompt. Cloud tests may incur a small API charge. A saved key is not proof of model access.")
                .font(.caption).foregroundStyle(Theme.text2)
            if workspace.provider.needsKey {
                Stepper("Monthly request limit on this device: \(workspace.monthlyLimit)", value: $workspace.monthlyLimit, in: 0...1000, step: 25)
                Text("\(workspace.attempts) attempts this UTC month. Includes tests and failures. This is separate from the Pod coach’s usage limit and is not a dollar budget.")
                    .font(.caption).foregroundStyle(Theme.text2)
            }
        }.disabled(workspace.busy)
            .onChange(of: workspace.provider) { key = ""; workspace.checkKey() }
            .onDisappear { key = "" }
    }
    private func saveKey() { workspace.saveKey(key); key = "" }
}
