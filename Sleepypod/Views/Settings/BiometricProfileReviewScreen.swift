import SwiftUI

struct BiometricProfileReviewScreen: View {
    let model: BiometricProfilesWorkspace
    let action: BiometricProfileAction
    let target: String?
    @State private var boundary = BiometricProfileBoundary.nextSession
    @State private var acknowledged = false
    @State private var compatibility: BiometricProfileCompatibility?
    @State private var checking = false
    @State private var compatibilityError: String?
    private var review: BiometricProfileReview? {
        guard let review = model.review, review.action == action, action != .activate || review.target == target else { return nil }
        return review
    }
    private var reviewIdentity: String { review.map { "\($0.action.rawValue):\($0.target ?? "defaults"):\($0.binding.generation):\($0.beforeHash):\($0.afterHash)" } ?? "none" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Compare against the saved profile. Configuration comparisons and schema checks do not establish agreement with reference measurements.").font(.footnote).foregroundStyle(Theme.text2)
                BiometricProfilePendingCard(model: model)
                if model.busy { ProgressView("Working…") }
                Button("Compare with saved profile", systemImage: "arrow.left.arrow.right") { Task { await model.compare(action: action, target: target) } }
                    .disabled(!model.canStartMutation).accessibilityIdentifier("profiles.compare")
                if let review {
                    comparison(review)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Manual application").font(.headline)
                        Text("This application is unvalidated. It can change heart rate, breathing rate, the HRV index, and dependent sleep stages.").font(.footnote).foregroundStyle(Theme.text2)
                        SettingsChoiceMenu(title: "Activation timing", selection: Binding(get: { boundary.rawValue }, set: { boundary = BiometricProfileBoundary(rawValue: $0) ?? .nextSession; acknowledged = false }), options: BiometricProfileBoundary.allCases.map { ($0.rawValue, $0.title) }, identifier: "profiles.boundary")
                            .disabled(!model.canStartMutation)
                        Text("Next session waits for a known empty-bed boundary. Immediate application still waits for a safe processing boundary.").font(.footnote).foregroundStyle(Theme.text2)
                        BridgeToggleRow(title: acknowledgement, value: $acknowledged, identifier: "profiles.acknowledge").disabled(!model.canApplyReview)
                        Button(action.title) { Task { await model.applyReviewed(boundary: boundary) } }
                            .buttonStyle(.borderedProminent).disabled(!acknowledged || !model.canApplyReview).accessibilityIdentifier("profiles.apply")
                    }.cardStyle()
                }
                if let event = model.event {
                    NavigationLink("Inspect last saved request") { BiometricActivationReceiptScreen(model: model, event: event) }
                        .accessibilityIdentifier("profiles.lastReceipt")
                }
                if action == .activate, let target {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Check schema compatibility") { Task { await check(target) } }.disabled(checking || model.busy)
                        if checking { ProgressView("Checking schema…") }
                        if let compatibility {
                            Text(compatibility.compatible ? "Schema and engine compatible" : "Incompatible").font(.subheadline)
                            Text("Agreement evidence: \(compatibility.evidence.replacingOccurrences(of: "_", with: " ")).").font(.footnote)
                            ForEach(compatibility.limitations, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.text2) }
                        }
                        if let compatibilityError { BiometricProfileError(error: compatibilityError) }
                    }.cardStyle()
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle(action == .activate ? "Candidate changes" : action.title).navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("profiles.reviewContent")
            .task { await model.compare(action: action, target: target) }
            .modifier(BiometricProfileObservation(model: model))
            .onChange(of: reviewIdentity) { acknowledged = false }
    }
    private var acknowledgement: String {
        switch action {
        case .activate: "I intend to apply this exact revision without validation evidence."
        case .reset: "I intend to restore system defaults without validation evidence."
        case .rollback: "I intend to restore the exact previous profile without validation evidence."
        }
    }
    private func comparison(_ review: BiometricProfileReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reviewed configuration").font(.headline)
            BiometricProfileIdentity(title: "Target revision", value: review.target ?? "System defaults")
            Text("Saved generation \(review.binding.generation)").font(.footnote)
            if let warning = review.recoveryWarning {
                BiometricProfileError(error: warning)
                Text("The pinned profile is incompatible. Its revision is preserved, but a valid before-and-after comparison is unavailable.").font(.footnote)
                BiometricProfileIdentity(title: "Preserved incompatible revision", value: review.binding.desiredRevisionId ?? "Legacy profile")
                BiometricProfileIdentity(title: "Default recovery configuration hash", value: review.afterHash)
            } else if let diff = review.diff {
                BiometricProfileIdentity(title: "Before configuration hash", value: diff.beforeHash)
                BiometricProfileIdentity(title: "After configuration hash", value: diff.afterHash)
                if diff.changes.isEmpty { Text("No resolved value changes.").font(.footnote).foregroundStyle(Theme.text2) }
                ForEach(diff.changes) { change in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(change.path).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        BiometricProfileIdentity(title: "Before", value: change.before.formattedJSON)
                        BiometricProfileIdentity(title: "After", value: change.after.formattedJSON)
                    }.padding(.vertical, 4)
                }
                Text("Override intent can change even when the resolved value stays the same.").font(.footnote).foregroundStyle(Theme.text2)
                if diff.intentChangedPaths.isEmpty { Text("No override intent changes.").font(.footnote) }
                ForEach(diff.intentChangedPaths, id: \.self) { Text($0).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true) }
            }
        }.cardStyle()
    }
    private func check(_ id: String) async {
        checking = true; compatibility = nil; compatibilityError = nil; defer { checking = false }
        do {
            let result = try await model.client.compatibility(side: model.side, id: id)
            guard !Task.isCancelled else { return }
            guard result.id == id else { throw APIError.serverError(message: "The compatibility response belongs to another revision.") }
            compatibility = result
        } catch { if !Task.isCancelled { compatibilityError = error.localizedDescription } }
    }
}

struct BiometricProfilePendingCard: View {
    let model: BiometricProfilesWorkspace
    @State private var confirmStop = false
    var body: some View {
        if model.pending != nil || model.mutationError != nil || model.notice != nil {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.mutationError { BiometricProfileError(error: error) }
                if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
                if let pending = model.pending {
                    Text("Retained request · \(pending.title)").font(.headline)
                    Text("Retry keeps the exact payload and request identity. No retry is sent automatically.").font(.footnote).foregroundStyle(Theme.text2)
                    DisclosureGroup("Request details") {
                        switch pending {
                        case .candidate(let request, let hash):
                            BiometricProfileIdentity(title: "Request identity", value: request.idempotencyKey)
                            BiometricProfileIdentity(title: "Candidate hash", value: hash)
                            BiometricProfileIdentity(title: "Parent", value: request.parentRevisionId ?? "New family")
                        case .activation(let request):
                            BiometricProfileIdentity(title: "Request identity", value: request.idempotencyKey)
                            BiometricProfileIdentity(title: "Revision", value: request.revisionId ?? "System defaults")
                            BiometricProfileIdentity(title: "Target hash", value: request.expectedResolvedHash)
                            Text("Generation \(request.expectedGeneration) · \(request.boundary.title)").font(.footnote)
                        }
                    }
                    Button("Retry exact request") { Task { await model.retryExactRequest() } }.disabled(model.busy).accessibilityIdentifier("profiles.retryExact")
                    }
                if model.hasUnresolvedRequest {
                    Button("Stop retrying", role: .destructive) { confirmStop = true }.disabled(model.busy)
                }
            }.cardStyle().confirmationDialog("Remove the retained retry?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Remove retained retry", role: .destructive) { Task { await model.stopRetrying() } }
            } message: { Text("This does not undo a change the controller may have saved. Inspect the profile and history before another action.") }
        }
    }
}
