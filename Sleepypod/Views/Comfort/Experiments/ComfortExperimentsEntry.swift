import SwiftUI
import FreeSleepKit

struct ComfortExperimentsEntry: View {
    @State private var model: ComfortExperimentWorkspace?
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    @AppStorage("household.boundaryRevision") private var householdRevision = ""
    @AppStorage("podURL") private var address = ""
    @AppStorage("apiBackend") private var backend = ""
    private var scope: String { [ownerRevision, householdRevision, address, backend].joined(separator: "|") }
    var body: some View {
        Group {
            if let model { ComfortExperimentsScreen(model: model) }
            else { ContentUnavailableView("Connect to your Pod", systemImage: "wifi", description: Text("Comfort comparisons use your saved owner connection. Open your personal account to use its private comparisons.")) }
        }
        .task(id: scope) {
            model?.invalidate(); model = nil
            guard !APIBackend.current.isDemo, !PersonalWorkspaceBoundary.isActive, let client = try? CoreRESTClient.configured() else { return }
            let revision = OwnerConnection.revision
            model = ComfortExperimentWorkspace(client: ComfortExperimentHTTPClient(account: .owner(client, revision: revision)),
                permitted: { !PersonalWorkspaceBoundary.isActive && OwnerConnection.revision == revision })
        }
        .onDisappear { model?.suspend() }
    }
}
