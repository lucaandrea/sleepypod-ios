import SwiftUI

struct MQTTSettingsScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MQTTSettingsWorkspace(client: APIBackend.current.isDemo ? DemoMQTTSettingsClient() : CoreMQTTSettingsClient())
    @State private var confirmReload = false
    @FocusState private var focusedField: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if APIBackend.current.isDemo { Text("DEMO · changes affect simulated settings only").font(.footnote).foregroundStyle(Theme.amber) }
                TimelineView(.periodic(from: .now, by: 1)) { _ in statusCard }
                if let settings = model.settings, let draft = model.draft {
                    fields(settings: settings, current: draft)
                    actions(draft: draft)
                } else if model.loading { ProgressView("Reading MQTT settings…") }
                if let error = model.settingsError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                if let error = model.actionError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                if let receipt = model.saveReceipt { Text(receipt).font(.footnote).accessibilityIdentifier("mqtt.saveReceipt") }
                Button("Reload settings from Pod") {
                    if model.dirty { confirmReload = true } else { Task { await model.loadSettings(discardDraft: true) } }
                }.disabled(model.loading || model.busy).accessibilityIdentifier("mqtt.reload")
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("MQTT")
            .scrollDismissesKeyboard(.interactively).accessibilityIdentifier("mqtt.content")
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedField = nil } } }
            .task(id: scenePhase) {
                guard scenePhase == .active else { model.clearSecret(); return }
                if model.settings == nil { await model.loadSettings() }
                repeat {
                    await model.refreshStatus()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                } while !Task.isCancelled
            }
            .onDisappear { model.clearSecret() }
            .confirmationDialog("Discard unsaved changes?", isPresented: $confirmReload, titleVisibility: .visible) {
                Button("Reload settings", role: .destructive) { Task { await model.loadSettings(discardDraft: true) } }
                Button("Cancel", role: .cancel) {}
            }
    }
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MQTT BRIDGE", systemImage: "antenna.radiowaves.left.and.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
            if let status = model.status, model.statusFresh() {
                Text(status.stateLabel).font(.headline).foregroundStyle(status.connected ? Theme.green : Theme.text1)
                observed("Published messages", value: status.messagesPublished.formatted())
                observed("Last publish", value: status.lastPublishAt.flatMap(SensorObservation.date)?.formatted(date: .abbreviated, time: .shortened) ?? "Never reported")
                Text(status.controlDescription).font(.footnote).foregroundStyle(Theme.text2)
                if let error = status.lastError { Text(model.draft?.safeMessage(error) ?? error).font(.footnote).foregroundStyle(Theme.amber) }
            } else { Text(model.loadingStatus ? "Checking connection…" : "Connection state unavailable").font(.subheadline).foregroundStyle(Theme.text2) }
            if let error = model.statusError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
        }.cardStyle()
    }
    private func fields(settings: MQTTSettings, current: MQTTSettingsDraft) -> some View {
        let binding = Binding(get: { model.draft ?? current }, set: { model.draft = $0 })
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                BridgeToggleRow(title: "MQTT bridge", value: binding.enabled, identifier: "mqtt.enabled")
                Text("Publishes status and biometrics to your broker.").font(.footnote).foregroundStyle(Theme.text2)
                BridgeToggleRow(title: "Home Assistant discovery", value: binding.haDiscovery, identifier: "mqtt.discovery")
                Text("Publishes climate and sensor entities.").font(.footnote).foregroundStyle(Theme.text2)
            }.cardStyle()
            VStack(alignment: .leading, spacing: 16) {
                textField("Broker URL", field: "url", text: binding.url, source: settings.sourceLabel("url"), keyboard: .URL)
                BridgeToggleRow(title: "TLS", value: binding.tlsEnabled, identifier: "mqtt.tls")
                Text("Use mqtts:// or wss:// for an encrypted connection. Certificate trust is configured on the Pod.").font(.footnote).foregroundStyle(Theme.text2)
                if let issue = current.brokerIssue, !current.brokerURL.isEmpty { Text(issue).font(.footnote).foregroundStyle(Theme.amber) }
            }.cardStyle()
            VStack(alignment: .leading, spacing: 16) {
                textField("Username", field: "username", text: binding.username, source: settings.sourceLabel("username"))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Replacement password").font(.subheadline.weight(.semibold))
                    SecureField(settings.passwordIsSet ? "Saved password unchanged" : "No saved password", text: binding.password)
                        .textFieldStyle(.roundedBorder).textContentType(.password).focused($focusedField, equals: "password")
                        .accessibilityIdentifier("mqtt.password").privacySensitive()
                    Text("\(settings.passwordIsSet ? "Password is set" : "Password is not set") · \(settings.sourceLabel("password"))").font(.caption).foregroundStyle(Theme.text2)
                }
                Text("Leave the replacement password blank to keep it when saving. Connection tests use only the password entered here.").font(.footnote).foregroundStyle(Theme.text2)
            }.cardStyle()
            VStack(alignment: .leading, spacing: 12) {
                textField("Topic prefix", field: "topicPrefix", text: binding.topicPrefix, source: settings.sourceLabel("topicPrefix"))
                if let issue = current.topicIssue { Text(issue).font(.footnote).foregroundStyle(Theme.amber) }
            }.cardStyle()
        }.disabled(model.busy || model.loading)
    }
    private func textField(_ title: String, field: String, text: Binding<String>, source: String, keyboard: UIKeyboardType = .asciiCapable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            TextField(title, text: text).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(keyboard).focused($focusedField, equals: field).accessibilityIdentifier("mqtt.\(field)")
            Text(source).font(.caption).foregroundStyle(Theme.text2)
        }
    }
    private func observed(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            Text(value).font(.subheadline).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
    private func actions(draft: MQTTSettingsDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = model.currentTestResult {
                Text(result.ok ? "Connection test succeeded. Settings have not been saved by this test." : "Connection test failed: \(result.error ?? "No further detail")")
                    .font(.footnote).foregroundStyle(result.ok ? Theme.green : Theme.amber).accessibilityIdentifier("mqtt.testResult")
            }
            Button(model.testing ? "Testing…" : "Test connection") { focusedField = nil; Task { await model.testConnection() } }
                .disabled(model.busy || model.loading || draft.brokerIssue != nil).accessibilityIdentifier("mqtt.test")
            Button(model.saving ? "Saving…" : "Save configuration") { focusedField = nil; Task { await model.save() } }
                .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                .disabled(model.busy || model.loading || model.mustRefresh || !model.dirty || draft.topicIssue != nil || (draft.enabled && draft.brokerIssue != nil))
                .accessibilityIdentifier("mqtt.save")
        }
    }
}
