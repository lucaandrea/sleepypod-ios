import SwiftUI
import UIKit

struct BedtimeRitualLifecycle: ViewModifier {
    let household: HouseholdWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ownerConnectionRevision") private var owner = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("household.boundaryRevision") private var boundary = ""
    @State private var workspace: BedtimeRitualWorkspace
    @State private var intent = BedtimeRitualIntentRoute.shared

    init(household: HouseholdWorkspace) {
        self.household = household
        _workspace = State(initialValue: BedtimeRitualWorkspace(personalContext: { household.active }) {
            if household.active { return try household.bedtimeAudioSession() }
            return try await BedtimeRitualConnection.owner()
        })
    }
    private var context: [String] { [owner, backend, endpoint, host, boundary] + household.bedtimeAudioContext }
    func body(content: Content) -> some View {
        content.environment(workspace)
            .sheet(isPresented: $workspace.presented) {
                NavigationStack { BedtimeRitualScreen(workspace: workspace) }
            }
            .onChange(of: context) { workspace.checkAccount() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { workspace.checkAccount(); workspace.session?.expire(); openIntent() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                workspace.withdraw()
            }
            .task(id: intent.request) { openIntent() }
            .onOpenURL { url in
                if url.absoluteString == "sleepypod-bedtime://open" { Task { await workspace.open() } }
                else { workspace.receive(url) }
            }
    }
    private func openIntent() {
        guard scenePhase == .active, intent.consume() else { return }
        Task { await workspace.open() }
    }
}

struct BedtimeRitualEntry: View {
    @Environment(BedtimeRitualWorkspace.self) private var workspace
    var body: some View {
        Button { Task { await workspace.open() } } label: {
            Label("Bedtime audio", systemImage: "homepodmini.2")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.accessibilityIdentifier("bedtime.open")
    }
}
