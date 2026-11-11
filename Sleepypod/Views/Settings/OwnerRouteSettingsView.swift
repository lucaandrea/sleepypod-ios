import SwiftUI
import FreeSleepKit

struct OwnerRouteSettingsView: View {
    @Environment(OwnerRouteSession.self) private var routes
    @Environment(\.scenePhase) private var phase
    @State private var homeAddress = ""
    @State private var awayAddress = ""
    @State private var homeKey = ""
    @State private var awayKey = ""
    @State private var homeStream = ""
    @State private var awayStream = ""
    @State private var validation: String?
    @State private var seeded = false
    @AccessibilityFocusState private var resultFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if APIBackend.current.isDemo {
                        Text("Example · simulated connections").font(.footnote).foregroundStyle(Theme.amber)
                            .accessibilityIdentifier("routes.practice")
                    }
                    Text("Connect at home and away without replacing your saved history or wake plan.")
                        .font(.body).fixedSize(horizontal: false, vertical: true)
                    if let profile = routes.profile {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(profile.routes.enabled ? "Automatic connection is on" : "Automatic connection is off",
                                  systemImage: profile.routes.enabled ? "checkmark.shield" : "pause.circle")
                                .font(.headline).accessibilityIdentifier("routes.state")
                            Button(profile.routes.enabled ? "Turn off automatic connection" : "Turn on automatic connection") {
                                routes.setEnabled(!profile.routes.enabled)
                            }.buttonStyle(.bordered).frame(minHeight: 44).accessibilityIdentifier("routes.toggle")
                            if let checkedAt = routes.checkedAt {
                                Text("Last checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }
                    }
                    routeFields(title: "Home connection", name: "home", address: $homeAddress, key: $homeKey, stream: $homeStream,
                                prompt: "http://your-pod.local:3000")
                    routeFields(title: "Away connection", name: "away", address: $awayAddress, key: $awayKey, stream: $awayStream,
                                prompt: "https://your-private-pod")
                    Text("Keep your current address in one of these connections. Each address needs its own saved key. The away address requires an authenticated HTTPS gateway; this screen does not create one.")
                        .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    Button(routes.busy ? "Checking connections…" : "Verify both and enable") { Task { await enroll() } }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("routes.verify")
                        .disabled(homeAddress.isEmpty || awayAddress.isEmpty)
                    if let message = validation ?? routes.message {
                        Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("routes.message").accessibilityFocused($resultFocused)
                            .id("routes.result")
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                                // The message's new measured height must drive scrolling at large text sizes.
                                proxy.scrollTo("routes.result", anchor: .bottom)
                            }
                    }
                    DisclosureGroup("How automatic connection works") {
                        Text("The app checks that both addresses belong to the same controller. It keeps a working connection and tries the verified alternative after a network failure. Rejected keys or certificate problems need attention. Reconnecting never repeats a bed command.")
                            .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }.font(.footnote)
                }.frame(maxWidth: 720).padding(16).padding(.bottom, 20).frame(maxWidth: .infinity)
                    .disabled(routes.busy)
            }.background(Theme.background).navigationTitle("Home and away").navigationBarTitleDisplayMode(.inline)
                .task { routes.beginEditing(); seed() }
                .onChange(of: validation ?? routes.message) { _, message in
                    guard message != nil else { return }
                    proxy.scrollTo("routes.result", anchor: .bottom); resultFocused = true
                }
                .onChange(of: homeAddress) { _, _ in homeKey = ""; validation = nil }
                .onChange(of: awayAddress) { _, _ in awayKey = ""; validation = nil }
                .onChange(of: phase) { _, next in
                    if next == .active { routes.reload() }
                    else { homeKey = ""; awayKey = ""; routes.invalidate() }
                }
                .onDisappear { homeKey = ""; awayKey = ""; routes.endEditing() }
        }
    }

    private func routeFields(title: String, name: String, address: Binding<String>, key: Binding<String>, stream: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            GroupedCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Address").font(.subheadline).foregroundStyle(Theme.text2)
                    TextField(title + " address", text: address, prompt: Text(prompt).foregroundStyle(Theme.text2), axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("routes.\(name).address")
                }.padding(16)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connection key").font(.subheadline).foregroundStyle(Theme.text2)
                    SecureField(title + " key", text: key, prompt: Text(savedKey(address.wrappedValue).isEmpty ? "Paste this address’s key" : "Saved · leave blank").foregroundStyle(Theme.text2))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .accessibilityIdentifier("routes.\(name).key")
                }.padding(16)
            }
            DisclosureGroup("Optional sensor stream") {
                TextField(title + " sensor stream", text: stream, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).frame(minHeight: 44)
                    .accessibilityIdentifier("routes.\(name).stream")
                Text("Use a secure stream at the same HTTPS host when away. Without it, ordinary controls can still connect.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }.font(.footnote)
        }
    }

    private func savedKey(_ address: String) -> String {
        guard let endpoint = try? UnifiedRuntime.validatedEndpoint(address) else { return "" }
        return routes.savedKey(for: endpoint.absoluteString)
    }

    private func seed() {
        guard !seeded else { return }; seeded = true
        routes.reload()
        if let profile = routes.profile {
            homeAddress = profile.routes.home.address; awayAddress = profile.routes.away.address
            homeStream = profile.routes.home.streamAddress; awayStream = profile.routes.away.streamAddress
        } else if URL(string: routes.currentAddress)?.scheme == "https" {
            awayAddress = routes.currentAddress
            awayStream = UserDefaults.standard.string(forKey: "podStreamURL") ?? ""
        } else {
            homeAddress = routes.currentAddress
            homeStream = UserDefaults.standard.string(forKey: "podStreamURL") ?? ""
        }
    }

    private func enroll() async {
        validation = nil
        do {
            let home = try OwnerConnectionCandidate(address: homeAddress, streamAddress: homeStream, backend: .sleepypodCore,
                token: homeKey.isEmpty ? savedKey(homeAddress) : homeKey)
            let away = try OwnerConnectionCandidate(address: awayAddress, streamAddress: awayStream, backend: .sleepypodCore,
                token: awayKey.isEmpty ? savedKey(awayAddress) : awayKey)
            if await routes.enroll(home: home, away: away) { homeKey = ""; awayKey = "" }
        } catch { validation = error.localizedDescription }
    }
}
