import SwiftUI

struct HomeConnectionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @AppStorage("podURL") private var address = ""
    @State private var home = AppleHomeService()
    @State private var bridge: HomeBridgeStatus?
    @State private var loading = false
    @State private var failure: String?
    @State private var refreshID = UUID()
    private var label: String {
        if loading { return "Checking bridge" }
        if failure != nil { return "Unavailable" }
        if bridge?.error != nil { return "Needs attention" }
        if bridge?.running == true { return "Bridge running" }
        return bridge?.enabled == true ? "Starting bridge" : "Bridge off"
    }
    var body: some View {
        FeatureSection(title: "Apple Home", eyebrow: "CONNECTED HOME", badge: label) {
            Text("Control each bed side's temperature, run base presets and use your Home scenes.").foregroundStyle(Theme.text2)
            if let failure { Text(failure).font(.subheadline).foregroundStyle(Theme.red) }
            else if let bridge {
                Text(bridge.running
                    ? "On your home network, open Apple Home, choose Add Accessory, then More options and select your Pod’s bridge. Enter the code below."
                    : "Enable the local Home bridge on your Pod to begin. Your Pod must be reachable on your home network for pairing.")
                    .font(.subheadline).foregroundStyle(Theme.text2)
                if bridge.running, let code = bridge.pairingCode { Text(code).font(.title2).monospacedDigit().textSelection(.enabled) }
                if let error = bridge.error { Text(error).font(.subheadline).foregroundStyle(Theme.red) }
            }
            Button(loading ? "Checking bridge…" : "Refresh bridge status") { refreshID = UUID() }
                .buttonStyle(GlassButtonStyle()).disabled(loading)
            Text("Bridge status does not confirm Apple Home pairing. Use your iPhone to authorize Home access and run scenes.")
                .font(.caption).foregroundStyle(Theme.text2)
            Divider()
            Text(home.state.message).font(.subheadline).foregroundStyle(Theme.text2)
            Button(home.state == .idle ? "Connect Apple Home" : "Refresh Apple Home") { home.connect() }
                .buttonStyle(GlassButtonStyle()).disabled(model.demo || home.execution.runningID != nil)
            if home.state == .denied || home.state == .restricted {
                Button("Open iPhone Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    .buttonStyle(GlassButtonStyle())
            }
            ForEach(home.homes) { house in
                Text(house.name).font(.headline)
                if house.scenes.isEmpty { Text("No scenes in this home yet.").font(.subheadline).foregroundStyle(Theme.text2) }
                ForEach(house.scenes) { scene in
                    Button(home.execution.runningID == scene.id ? "Running \(scene.name)…" : "Run \(scene.name)") {
                        Task { await home.run(scene, in: house) }
                    }.buttonStyle(GlassButtonStyle()).disabled(home.execution.runningID != nil || model.demo)
                }
            }
            if let message = home.execution.message {
                Text(message).font(.subheadline).foregroundStyle(home.execution.failed ? Theme.red : Theme.green)
            }
            if model.demo { Text("Apple Home access and scene execution are unavailable in demo mode.").font(.caption).foregroundStyle(Theme.text2) }
        }.task(id: "\(address)|\(model.connectionRevision)|\(refreshID)") { await loadBridge() }
            .onChange(of: phase) { if phase == .active { home.refresh() } }
    }
    private func loadBridge() async {
        loading = true; failure = nil; bridge = nil
        do {
            let value: HomeBridgeStatus = model.demo ? .init(enabled: false, running: false, pairingCode: nil, error: nil)
                : try await PodClient.configured().get("integrations/homekit")
            guard !Task.isCancelled else { return }; bridge = value; loading = false
        } catch {
            guard !Task.isCancelled else { return }
            failure = "Bridge status is unavailable. Check your saved Pod connection and retry."; loading = false
        }
    }
}
