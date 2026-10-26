import SwiftUI

struct NetworkSettingsScreen: View {
    @Environment(StatusManager.self) private var status
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirming = false
    @State private var requestedBlock = false
    @State private var receipt: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if APIBackend.current.isDemo { Text("DEMO · changes affect simulated settings only").font(.footnote).foregroundStyle(Theme.amber) }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 16) {
                        Label("INTERNET", systemImage: "globe").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                        Text(status.isChangingInternet ? "Changing…" : status.internetIsFresh() ? (status.isInternetBlocked ? "Local only" : "Internet allowed") : "State unavailable")
                            .font(.headline).accessibilityIdentifier("network.state")
                        Text("Local only keeps the Pod from reaching external servers. Your local network connection remains available.")
                            .font(.subheadline).foregroundStyle(Theme.text2)
                        if status.internetIsFresh() || status.isChangingInternet {
                            BridgeToggleRow(title: "Internet access", value: Binding(get: { !status.isInternetBlocked }, set: { enabled in
                                requestedBlock = !enabled; confirming = true
                            }), identifier: "network.internet")
                            .disabled(status.isChangingInternet || confirming)
                        }
                        Button("Refresh network state") { Task { await status.fetchAll() } }
                            .disabled(status.isLoading || status.isChangingInternet).accessibilityIdentifier("network.refresh")
                    }.cardStyle()
                }
                if let error = status.internetError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                if let receipt { Text(receipt).font(.footnote).accessibilityIdentifier("network.receipt") }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Network").accessibilityIdentifier("network.content")
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    await status.fetchAll()
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                } while !Task.isCancelled
            }
            .confirmationDialog(requestedBlock ? "Block internet access?" : "Allow internet access?", isPresented: $confirming, titleVisibility: .visible) {
                Button(requestedBlock ? "Block internet" : "Allow internet") {
                    let requested = requestedBlock
                    Task {
                        receipt = nil
                        guard status.internetIsFresh(), !status.isChangingInternet else { return }
                        await status.setInternetAccess(blocked: requested)
                        if status.internetIsFresh(), status.isInternetBlocked == requested {
                            receipt = requested ? "The Pod confirmed local-only access." : "The Pod confirmed internet access is allowed."
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(requestedBlock ? "Online updates and external services will be unavailable while the Pod is local only."
                    : "The Pod will be able to connect to external servers.")
            }
    }
}
