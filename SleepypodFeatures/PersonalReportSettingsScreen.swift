import SwiftUI

struct PersonalReportSettingsScreen: View {
    @Bindable var model: PersonalReportWorkspace
    @State private var draft = PersonalReportPreferences()
    @State private var key = ""
    private enum Field: Hashable { case model, address, key }
    @FocusState private var focusedField: Field?
    @Environment(\.scenePhase) private var phase
    private var changed: Bool { draft != model.preferences }
    var body: some View {
        Form {
            if phase != .active || !model.available {
                ContentUnavailableView("Reopen your personal account", systemImage: "lock")
            } else {
                Section("Your model") {
                    Picker("Provider", selection: Binding(get: { draft.provider }, set: { provider in
                        draft.provider = provider; draft.model = provider.models[0]; key = ""; model.cancel()
                    })) {
                        ForEach(IntelligenceProvider.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("personalReports.provider")
                    if draft.provider == .apple {
                        Text(AppleIntelligenceClient.availability).font(.subheadline)
                        Text("The default is Apple’s on-device model. Choosing another provider never sends a report automatically.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    } else {
                        TextField("API model ID", text: $draft.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .model)
                            .accessibilityIdentifier("personalReports.modelID")
                        if draft.provider == .ollama {
                            TextField("Your Ollama server URL", text: $draft.localAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .focused($focusedField, equals: .address)
                            Text("A local server receives your summary over the network. Gemma does not run on this iPhone through this option.")
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                    if draft.provider.needsKey {
                        Stepper("Monthly request limit: \(draft.monthlyLimit)", value: $draft.monthlyLimit, in: 0...1000, step: 25)
                        Text("\(model.attempts) attempts this UTC month for this account on this device, including tests and failed requests. This is not a dollar budget.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                    Button("Save model settings") { focusedField = nil; model.configure(draft) }.disabled(!changed || !model.mayRequest)
                        .accessibilityIdentifier("personalReports.saveModel")
                }.disabled(model.busy)
                if model.preferences.provider.needsKey, !changed {
                    Section("Your provider key") {
                        Text(model.hasKey ? "Personal API key saved on this device" : "Add your own API key")
                        SecureField("Paste API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                            .focused($focusedField, equals: .key)
                        Button("Save personal key") { focusedField = nil; model.saveKey(key); key = "" }.disabled(key.isEmpty || !model.mayRequest)
                        if model.hasKey { Button("Remove personal key", role: .destructive) { model.removeKey() }.foregroundStyle(Theme.red) }
                        Text("This account has its own Keychain entry. Your partner’s and household owner’s keys are not reused. Requests go directly to the selected provider.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }.disabled(model.busy)
                }
                if !changed {
                    Section("Verify access") {
                        if model.preferences.provider != .apple {
                            Menu("Choose an available model") {
                                ForEach(model.models, id: \.self) { identifier in
                                    Button(identifier) { draft.model = identifier }
                                }
                            }
                            Button("Refresh available models") { Task { await model.refreshModels() } }
                        }
                        Button("Test model connection") { focusedField = nil; Task { await model.testModel() } }
                            .accessibilityIdentifier("personalReports.testModel")
                        Text("The test sends a short test prompt without Health or Pod evidence. Provider charges may apply.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }.disabled(!model.mayRequest)
                }
                if model.busy { ProgressView("Checking…"); Button("Cancel request") { model.cancel() } }
                if let message = model.message { Section { Text(message).font(.subheadline) } }
            }
        }.scrollContentBackground(.hidden).background(Theme.background).scrollDismissesKeyboard(.interactively)
            .navigationTitle("Your model").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if focusedField != nil { Spacer(); Button("Done") { focusedField = nil } }
                }
            }
            .onAppear { draft = model.preferences }
            .onChange(of: draft) { model.discardReview() }
            .onChange(of: phase) { if phase != .active { key = ""; model.cancel() } }
            .onDisappear { focusedField = nil; key = ""; model.cancel() }
    }
}
