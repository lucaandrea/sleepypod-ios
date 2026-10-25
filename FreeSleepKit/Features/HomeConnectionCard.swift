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
        SleepCard(title: "Apple Home", eyebrow: "CONNECTED HOME", badge: label) {
            Text("Control each bed side's temperature, run base presets and use your Home scenes.").foregroundStyle(SleepTheme.secondary)
            if let failure { Text(failure).sleepText(.small).foregroundStyle(SleepTheme.error) }
            else if let bridge {
                Text(bridge.running
                    ? "On your home network, open Apple Home, choose Add Accessory, then More options and select Free Sleep. Enter the code below."
                    : "Enable the local Home bridge on your Pod to begin. Your Pod must be reachable on your home network for pairing.")
                    .sleepText(.small).foregroundStyle(SleepTheme.secondary)
                if bridge.running, let code = bridge.pairingCode { Text(code).sleepText(.pageTitle).monospacedDigit().textSelection(.enabled) }
                if let error = bridge.error { Text(error).sleepText(.small).foregroundStyle(SleepTheme.error) }
            }
            Button(loading ? "Checking bridge…" : "Refresh bridge status") { refreshID = UUID() }
                .buttonStyle(SleepButtonStyle(fill: true)).disabled(loading)
            Text("Bridge status does not confirm Apple Home pairing. Use your iPhone to authorize Home access and run scenes.")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            Divider()
            Text(home.state.message).sleepText(.small).foregroundStyle(SleepTheme.secondary)
            Button(home.state == .idle ? "Connect Apple Home" : "Refresh Apple Home") { home.connect() }
                .buttonStyle(SleepButtonStyle(fill: true)).disabled(model.demo || home.execution.runningID != nil)
            if home.state == .denied || home.state == .restricted {
                Button("Open iPhone Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    .buttonStyle(SleepButtonStyle(fill: true))
            }
            ForEach(home.homes) { house in
                Text(house.name).sleepText(.cardTitle)
                if house.scenes.isEmpty { Text("No scenes in this home yet.").sleepText(.small).foregroundStyle(SleepTheme.secondary) }
                ForEach(house.scenes) { scene in
                    Button(home.execution.runningID == scene.id ? "Running \(scene.name)…" : "Run \(scene.name)") {
                        Task { await home.run(scene, in: house) }
                    }.buttonStyle(SleepButtonStyle(fill: true)).disabled(home.execution.runningID != nil || model.demo)
                }
            }
            if let message = home.execution.message {
                Text(message).sleepText(.small).foregroundStyle(home.execution.failed ? SleepTheme.error : SleepTheme.success)
            }
            if model.demo { Text("Apple Home access and scene execution are unavailable in demo mode.").sleepText(.caption).foregroundStyle(SleepTheme.secondary) }
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
