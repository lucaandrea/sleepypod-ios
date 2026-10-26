import SwiftUI

struct BiometricProfileLibraryScreen: View {
    let model: BiometricProfilesWorkspace
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("A saved revision is not evidence of validation or processor adoption.").font(.footnote).foregroundStyle(Theme.text2)
                NavigationLink { BiometricCandidateScreen(profile: model, parentID: nil) } label: { Label("New candidate from current profile", systemImage: "plus") }
                    .disabled(!model.canStartMutation).accessibilityIdentifier("profiles.new")
                BiometricProfilePendingCard(model: model)
                if model.loadingProfiles { ProgressView("Loading profiles…") }
                if let error = model.profilesError { BiometricProfileError(error: error) }
                Button("Reload profiles", systemImage: "arrow.clockwise") { Task { await model.loadProfiles(cursor: model.profileCursor) } }.disabled(model.loadingProfiles)
                if let page = model.profiles {
                    if page.items.isEmpty { Text("No saved candidate revisions.").foregroundStyle(Theme.text2) }
                    ForEach(page.items) { profile in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Revision \(profile.revision)").font(.headline)
                            Text("\(profile.origin.capitalized) · \(profile.requester)").font(.footnote).foregroundStyle(Theme.text2)
                            BiometricProfileDate(title: "Created", milliseconds: profile.createdAtMs)
                            BiometricProfileIdentity(title: "Revision", value: profile.id)
                            NavigationLink("Edit a new candidate") { BiometricCandidateScreen(profile: model, parentID: profile.id) }.disabled(!model.canStartMutation)
                                .accessibilityIdentifier("profiles.edit.\(profile.id)")
                            NavigationLink("Inspect candidate changes") { BiometricProfileReviewScreen(model: model, action: .activate, target: profile.id) }.disabled(!model.canStartMutation)
                                .accessibilityIdentifier("profiles.inspect.\(profile.id)")
                            DisclosureGroup("Pinned configuration and overrides") {
                                VStack(alignment: .leading, spacing: 10) {
                                    BiometricProfileIdentity(title: "Configuration hash", value: profile.resolvedHash)
                                    BiometricProfileIdentity(title: "Engine manifest hash", value: profile.baseManifestHash)
                                    BiometricProfileIdentity(title: "Parent revision", value: profile.parentRevisionId ?? "New family")
                                    BiometricProfileIdentity(title: "Family", value: profile.familyId)
                                    ForEach(profile.overrides) { override in BiometricProfileIdentity(title: override.path, value: override.value.formattedJSON) }
                                    DisclosureGroup("Resolved configuration") { Text(profile.resolved.formattedJSON).font(.caption.monospaced()).textSelection(.enabled) }
                                }.padding(.top, 8)
                            }
                        }.cardStyle()
                    }
                    if model.profileCursor != nil { Button("Newest profiles") { Task { await model.loadProfiles() } }.disabled(model.loadingProfiles) }
                    if let cursor = page.nextCursor { Button("Older profiles") { Task { await model.loadProfiles(cursor: cursor) } }.disabled(model.loadingProfiles) }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Profiles").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("profiles.libraryContent").task { await model.loadProfiles(cursor: model.profileCursor) }
            .modifier(BiometricProfileObservation(model: model))
    }
}

struct BiometricProfileHistoryScreen: View {
    let model: BiometricProfilesWorkspace
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Saved activation events record intent. Inspect a request for processor acknowledgements; check Overview for current health.").font(.footnote).foregroundStyle(Theme.text2)
                if model.loadingHistory { ProgressView("Loading history…") }
                if let error = model.historyError { BiometricProfileError(error: error) }
                Button("Reload history", systemImage: "arrow.clockwise") { Task { await model.loadHistory(beforeGeneration: model.historyCursor) } }.disabled(model.loadingHistory)
                if let page = model.history {
                    if page.items.isEmpty { Text("No profile changes have been saved for this side.").foregroundStyle(Theme.text2) }
                    ForEach(page.items) { event in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(event.action.capitalized) · generation \(event.generation)").font(.headline)
                            BiometricProfileValue("Saved event state", value: BiometricProfileLabels.state(event.state))
                            BiometricProfileDate(title: "Requested", milliseconds: event.createdAtMs)
                            Text("Requested by \(event.requester)").font(.footnote).foregroundStyle(Theme.text2)
                            if let reason = event.reason { BiometricProfileError(error: reason) }
                            NavigationLink("Inspect request") { BiometricActivationReceiptScreen(model: model, event: event) }
                                .accessibilityIdentifier("profiles.event.\(event.id)")
                            DisclosureGroup("Configuration and evidence") {
                                VStack(alignment: .leading, spacing: 8) {
                                    BiometricProfileIdentity(title: "Request", value: event.id)
                                    BiometricProfileIdentity(title: "Before revision", value: event.previousRevisionId ?? "System defaults")
                                    BiometricProfileIdentity(title: "After revision", value: event.nextRevisionId ?? "System defaults")
                                    BiometricProfileIdentity(title: "Before hash", value: event.previousHash)
                                    BiometricProfileIdentity(title: "After hash", value: event.nextHash)
                                    if let evaluation = event.evaluationId { BiometricProfileIdentity(title: "Evaluation", value: evaluation) }
                                    BiometricProfileIdentity(title: "Evidence", value: event.evidence.formattedJSON)
                                }.padding(.top, 8)
                            }
                        }.cardStyle()
                    }
                    if model.historyCursor != nil { Button("Newest events") { Task { await model.loadHistory() } }.disabled(model.loadingHistory) }
                    if let cursor = page.nextGeneration { Button("Older events") { Task { await model.loadHistory(beforeGeneration: cursor) } }.disabled(model.loadingHistory) }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Profile history").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("profiles.historyContent").task { await model.loadHistory(beforeGeneration: model.historyCursor) }
    }
}

struct BiometricActivationReceiptScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: BiometricProfilesWorkspace
    let event: BiometricActivationEvent
    @State private var status: BiometricActivationStatus?
    @State private var error: String?
    @State private var observedAt: Date?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Activation request saved").font(.headline)
                Text("Processor acknowledgement is reported separately below.").font(.footnote).foregroundStyle(Theme.text2)
                BiometricProfileIdentity(title: "Request", value: event.id)
                BiometricProfileDate(title: "Requested", milliseconds: event.createdAtMs)
                if let error { BiometricProfileError(error: error) }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let status {
                        Text(BiometricProfileLabels.state(status.observedState)).font(.headline)
                        if !SensorObservation.fresh(observedAt, age: 15, now: .now) || error != nil { Text("Last observation · refresh needed").font(.footnote).foregroundStyle(Theme.amber) }
                        if !status.isCurrent { Text("This request has been superseded by another profile change.").foregroundStyle(Theme.amber) }
                        if let delivery = status.deliveryState { BiometricProfileValue("Delivery", value: delivery.capitalized) }
                        BiometricProfileReceipts(receipts: status.receipts)
                    } else if error == nil { ProgressView("Reading processor acknowledgement…") }
                }
                Text("Check Overview for current processor health. A past acknowledgement does not prove current health.").font(.footnote).foregroundStyle(Theme.text2)
                Button("Refresh request") { Task { await refresh() } }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Activation request").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("profiles.receiptContent")
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }
    private func refresh() async {
        do {
            let result = try await model.client.activationStatus(side: model.side, id: event.id)
            guard !Task.isCancelled else { return }
            guard result.event?.id == event.id, result.event?.side == model.side else { throw APIError.serverError(message: "The processor report belongs to a different request.") }
            status = result; observedAt = .now; error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
