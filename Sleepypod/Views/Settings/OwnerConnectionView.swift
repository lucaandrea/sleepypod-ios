import SwiftUI
import FreeSleepKit

struct OwnerConnectionView: View {
    @Environment(DeviceManager.self) private var device
    @Environment(SettingsManager.self) private var settings
    @Environment(SensorStreamService.self) private var stream
    @Environment(ScheduleManager.self) private var schedules
    @Environment(MetricsManager.self) private var metrics
    @Environment(StatusManager.self) private var status
    @State private var address = OwnerConnection.displayAddress
    @State private var token = ""
    @State private var message: String?
    @State private var saving = false
    @State private var backend = APIBackend.current == .freeSleep ? APIBackend.freeSleep : .sleepypodCore
    @State private var streamAddress = UserDefaults.standard.string(forKey: "podStreamURL") ?? ""

    private var hasSavedKey: Bool { !UnifiedRuntime.savedKey(for: address.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GroupedSection("CONTROLLER") {
                    GroupedCard {
                        SettingsRow("Software", icon: "cpu") {
                            Picker("Controller", selection: $backend) {
                                Text("Sleepypod Core").tag(APIBackend.sleepypodCore)
                                Text("Existing Pod").tag(APIBackend.freeSleep)
                            }.labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Address").font(.subheadline).foregroundStyle(Theme.text2)
                            TextField("https://your-pod or http://192.168.1.88:3000", text: $address)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .accessibilityLabel("Pod controller address")
                        }.padding(16)
                        SecureField(hasSavedKey ? "Saved key · leave blank to keep" : "Connection key (if required)", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().padding(16)
                            .accessibilityIdentifier("connection.key")
                    }
                    Text(hasSavedKey
                         ? "A connection key is saved in this iPhone’s Keychain. It will be reused unless you enter a replacement."
                         : "Local controllers may connect without a key. If your controller requires one, it stays in this iPhone’s Keychain. Use your private HTTPS address for remote access.")
                        .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16)
                }
                GroupedSection("SENSOR STREAM") {
                    GroupedCard {
                        TextField("Optional wss:// sensor stream address", text: $streamAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).padding(16)
                    }
                    Text("Leave blank to use the controller’s local stream on port 3001.").font(.footnote)
                        .foregroundStyle(Theme.text2).padding(.horizontal, 16)
                }
                Button(saving ? "Connecting…" : "Save and connect") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(saving || address.isEmpty)
                if let message { Text(message).font(.footnote).accessibilityAddTraits(.updatesFrequently) }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
        }.background(Theme.background).navigationTitle("Pod connection")
            .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .onChange(of: address) { _, _ in token = "" }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let candidate = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let key = token.isEmpty ? UnifiedRuntime.savedKey(for: candidate) : token
            guard key.isEmpty || key.count >= 32 else { message = "Enter the complete connection key (at least 32 characters), or leave blank for a local controller without a key."; return }
            if !streamAddress.isEmpty {
                guard let endpoint = URL(string: candidate), let streamURL = URL(string: streamAddress),
                      streamURL.host == endpoint.host, streamURL.user == nil, streamURL.password == nil,
                      streamURL.query == nil, streamURL.fragment == nil,
                      streamURL.scheme == (endpoint.scheme == "https" ? "wss" : "ws") else {
                    message = "The stream must use the same host and matching secure transport as your controller."; return
                }
            }
            try UnifiedRuntime.configure(address: candidate, token: key, core: backend == .sleepypodCore)
            UserDefaults.standard.set(streamAddress, forKey: "podStreamURL")
            APIBackend.current = backend
            UserDefaults.standard.set(UUID().uuidString, forKey: "ownerConnectionRevision")
            settings.podIP = OwnerConnection.endpoint?.host ?? ""
            stream.disconnect()
            let client = backend.createClient()
            device.switchBackend(client); settings.switchBackend(client); schedules.switchBackend(client)
            metrics.switchBackend(client); status.switchBackend(client)
            await device.fetchStatus()
            if device.isConnected { stream.connect() }
            message = device.isConnected ? "Connected to your controller." : "Saved. The controller did not respond; check its address and key."
            token = ""
        } catch { message = error.localizedDescription }
    }
}
