import SwiftUI
import FreeSleepKit

struct OwnerConnectionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var enrollment = OwnerConnectionEnrollment()
    @AccessibilityFocusState private var messageFocused: Bool
    #if DEBUG
    @State private var example = OwnerConnectionExample.configured()
    #endif
    @State private var backend = APIBackend.current == .freeSleep ? APIBackend.freeSleep : .sleepypodCore
    @State private var streamAddress = UserDefaults.standard.string(forKey: "podStreamURL") ?? ""

    private var normalizedAddress: String? { try? UnifiedRuntime.validatedEndpoint(address).absoluteString }
    private var hasSavedKey: Bool { normalizedAddress.map { !UnifiedRuntime.savedKey(for: $0).isEmpty } ?? false }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 22) {
                #if DEBUG
                if example != nil {
                    Text("Example · simulated connection").font(.footnote)
                        .accessibilityIdentifier("connection.practice")
                }
                #endif
                GroupedSection("CONTROLLER") {
                    GroupedCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Software").font(.subheadline).foregroundStyle(Theme.text2)
                            Menu {
                                Picker("Controller", selection: $backend) {
                                    Text("Sleepypod Core").tag(APIBackend.sleepypodCore)
                                    Text("Existing Pod").tag(APIBackend.freeSleep)
                                }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(backend == .sleepypodCore ? "Sleepypod Core" : "Existing Pod")
                                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.up.chevron.down").font(.footnote).accessibilityHidden(true)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.accessibilityLabel("Controller software")
                                .accessibilityValue(backend == .sleepypodCore ? "Sleepypod Core" : "Existing Pod")
                                .accessibilityIdentifier("connection.software")
                        }.padding(16)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Address").font(.subheadline).foregroundStyle(Theme.text2)
                            TextField("Pod controller address", text: $address, prompt: Text("https://your-pod").foregroundStyle(Theme.text2), axis: .vertical)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                                .accessibilityLabel("Pod controller address")
                                .accessibilityIdentifier("connection.address")
                        }.padding(16)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Connection key").font(.subheadline).foregroundStyle(Theme.text2)
                            SecureField("Connection key", text: $token,
                                        prompt: Text(hasSavedKey ? "Saved · leave blank" : "Paste key if required").foregroundStyle(Theme.text2))
                                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                                .accessibilityIdentifier("connection.key")
                        }.padding(16)
                    }
                    Text(hasSavedKey
                         ? "A connection key is saved in this device’s Keychain. It will be reused unless you enter a replacement."
                         : "Local controllers may connect without a key. If your controller requires one, it stays in this device’s Keychain. Use your private HTTPS address for remote access.")
                        .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16)
                }
                GroupedSection("SENSOR STREAM") {
                    GroupedCard {
                        TextField("Optional sensor stream address", text: $streamAddress, prompt: Text("wss://your-pod/sensors").foregroundStyle(Theme.text2), axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).padding(16)
                            .accessibilityLabel("Optional sensor stream address")
                    }
                    Text("Optional. A local HTTP controller uses port 3001 when blank. HTTPS connections need an explicit secure stream address; ordinary controls still use the controller connection.").font(.footnote)
                        .foregroundStyle(Theme.text2).padding(.horizontal, 16)
                }
                Text("The address and key are checked before replacing your saved connection. This check reads status and does not change the bed.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                Button(saving ? "Checking connection…" : "Verify and connect") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(saving || address.isEmpty)
                    .accessibilityIdentifier("connection.verify")
                if let message {
                    Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently).accessibilityIdentifier("connection.message")
                        .id("connection.result").accessibilityFocused($messageFocused)
                }
            }.frame(maxWidth: 720).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
                .frame(maxWidth: .infinity).disabled(saving)
            #if DEBUG
            if let example, saving, example.waiting {
                Button("Complete simulated reply") { example.complete() }.frame(minHeight: 44)
                    .accessibilityIdentifier("connection.example.complete")
            }
            #endif
        }.background(Theme.background).navigationTitle("Pod connection")
            .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .onChange(of: message) { _, value in
                guard value != nil else { messageFocused = false; return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo("connection.result", anchor: .bottom)
                }
                messageFocused = true
            }
            .onChange(of: address) { _, _ in token = "" }
            .onDisappear {
                enrollment.invalidate()
                #if DEBUG
                example?.cancel()
                #endif
            }
        }
    }

    private func save() async {
        saving = true
        message = nil
        defer { saving = false }
        do {
            let endpoint = try UnifiedRuntime.validatedEndpoint(address)
            let key = token.isEmpty ? UnifiedRuntime.savedKey(for: endpoint.absoluteString) : token
            let candidate = try OwnerConnectionCandidate(address: endpoint.absoluteString, streamAddress: streamAddress, backend: backend, token: key)
            #if DEBUG
            if let example {
                let original = OwnerConnection.revision
                let verified = await enrollment.connect(candidate, check: { try await example.check($0) },
                    isCurrent: { OwnerConnection.revision == original && APIBackend.current.isDemo }, commit: { _ in })
                message = verified ? "Example connection verified. No saved settings changed." : enrollment.message
                return
            }
            #endif
            let previous = OwnerConnection.revision
            let committed = await enrollment.connect(candidate, check: { try await $0.check() }, isCurrent: {
                OwnerConnection.revision == previous && !PersonalWorkspaceBoundary.isActive
            }, commit: { checked in
                try UnifiedRuntime.configure(address: checked.endpoint.absoluteString, token: checked.token, core: checked.backend == .sleepypodCore)
                UserDefaults.standard.set(checked.streamAddress, forKey: "podStreamURL")
                APIBackend.current = checked.backend
                UserDefaults.standard.set(UUID().uuidString, forKey: "ownerConnectionRevision")
                settings.podIP = checked.endpoint.host ?? ""
                stream.disconnect()
                let client = checked.backend.createClient()
                device.switchBackend(client); settings.switchBackend(client); schedules.switchBackend(client)
                metrics.switchBackend(client); status.switchBackend(client)
            })
            guard committed else { message = enrollment.message; return }
            let committedRevision = OwnerConnection.revision
            await device.fetchStatus()
            guard committedRevision == OwnerConnection.revision, !PersonalWorkspaceBoundary.isActive else { return }
            if device.isConnected { stream.connect() }
            message = device.isConnected ? "Connected to your controller." : "Connection verified and saved. Waiting for a fresh status; the network may have changed."
            token = ""
        } catch { message = error.localizedDescription }
    }
}
