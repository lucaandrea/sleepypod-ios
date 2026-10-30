import SwiftUI

struct DisconnectedTabView: View {
    let tab: String
    var selectedTab: Binding<String>?
    @Environment(DeviceManager.self) private var device
    @Environment(SettingsManager.self) private var settings
    @Environment(PodDiscovery.self) private var discovery
    @Environment(\.openURL) private var openURL

    private var permissionDenied: Bool {
        device.connectionIssue != .authentication && (device.localNetworkAccessDenied || discovery.status == .permissionRequired)
    }
    private var searching: Bool {
        switch discovery.status {
        case .scanning, .found, .resolving: true
        default: false
        }
    }
    private var title: String {
        if permissionDenied { return "Allow Local Network access" }
        if searching { return "Looking for your Pod" }
        if let issue = device.connectionIssue { return issue.title }
        if discovery.status == .failed { return "Pod could not be found" }
        return device.hasPodIP ? "Connecting to your Pod" : "Connect your Pod"
    }
    private var explanation: String {
        if permissionDenied { return "iOS has blocked local discovery. Enable Local Network for sleepypod in Settings, then retry." }
        if let issue = device.connectionIssue { return issue.detail }
        if discovery.status == .failed { return "No controller responded during discovery. Retry or review the saved address in Pod connection." }
        if searching { return "Checking your saved address and nearby controllers. Discovery may be unavailable even when a saved address works." }
        return "Checking the saved controller address. A local Pod needs a reachable local network; a private HTTPS controller can also use remote access."
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                PodDiscoveryMark(scanning: searching || device.isConnecting).padding(.top, 24)
                VStack(spacing: 10) {
                    Text(title).font(.title2.bold()).accessibilityIdentifier("connection.title")
                    Text(explanation).font(.subheadline).foregroundStyle(Theme.text2)
                }.multilineTextAlignment(.center)
                if !OwnerConnection.displayAddress.isEmpty {
                    VStack(spacing: 6) {
                        Text("Saved controller").font(.caption).foregroundStyle(Theme.text2)
                        Text(OwnerConnection.displayAddress).font(.subheadline.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("connection.savedAddress")
                        if let updated = device.lastUpdated {
                            Text("Last response \(updated.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(Theme.text2)
                        }
                    }.frame(maxWidth: .infinity).padding(16).background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                }
                Button(device.isConnecting || searching ? "Checking connection…" : "Retry connection") {
                    if OwnerConnection.endpoint != nil { device.retryConnection() }
                    else { Task { _ = await discovery.autoConnect(settingsManager: settings, deviceManager: device) } }
                }.buttonStyle(PrimaryButtonStyle()).disabled(device.isConnecting || searching)
                    .accessibilityIdentifier("connection.retry")
                NavigationLink("Pod connection", destination: OwnerConnectionView())
                    .buttonStyle(GlassButtonStyle()).accessibilityIdentifier("connection.settings")
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.font(.subheadline).frame(minHeight: 44)
                Text("Connection checks only read status. They do not repeat temperature, power or bed-position commands.")
                    .font(.caption).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            }.padding(.horizontal, 16).padding(.bottom, 24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.background(Theme.background)
    }
}
