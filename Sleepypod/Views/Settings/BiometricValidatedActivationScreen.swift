import SwiftUI

struct BiometricValidatedActivationScreen: View {
    let selection: BiometricValidatedSelection
    let client: any BiometricProfilesServing
    @State private var model: BiometricProfilesWorkspace?
    @State private var error: String?
    @State private var boundary = BiometricProfileBoundary.nextSession
    var body: some View {
        BiometricReportPage(title: "Apply evaluated profile") {
            ReferenceSideValue(side: selection.side)
            Text("Apply this exact candidate using its retained evaluation. Core checks the evidence and current settings again when applying.").foregroundStyle(Theme.text2)
            Text("Agreement with a named reference does not establish clinical accuracy.").font(.footnote).foregroundStyle(Theme.text2)
            DisclosureGroup("Selected candidate and evaluation") {
                VStack(alignment: .leading, spacing: 12) {
                    BiometricProfileIdentity(title: "Candidate revision", value: selection.revisionId)
                    BiometricProfileIdentity(title: "Resolved configuration", value: selection.expectedResolvedHash)
                    BiometricProfileIdentity(title: "Evaluation", value: selection.evaluationId)
                    BiometricProfileIdentity(title: "Complete report hash", value: selection.expectedReportHash)
                }.padding(.top, 8)
            }.cardStyle().accessibilityIdentifier("validated.selection")
            if let error { BiometricProfileError(error: error) }
            if let model {
                if let event = model.event, event.evaluationId == selection.evaluationId,
                   event.nextRevisionId == selection.revisionId, event.nextHash == selection.expectedResolvedHash {
                    Text("Application request saved").font(.headline).accessibilityIdentifier("validated.saved")
                    Text("Saving the request does not confirm processor adoption. Inspect its acknowledgement and current health.").font(.footnote).foregroundStyle(Theme.text2)
                    NavigationLink { BiometricActivationReceiptScreen(model: model, event: event) } label: { Label("Inspect processor acknowledgement", systemImage: "checkmark.message") }
                        .accessibilityIdentifier("validated.receipt")
                } else {
                    BiometricReportMenu(title: "Activation timing", selection: $boundary, options: BiometricProfileBoundary.allCases) { $0.title }
                        .disabled(model.busy || model.hasUnresolvedRequest).accessibilityIdentifier("validated.boundary")
                    Text("Next session waits for the next session boundary. Immediate waits for a processing boundary; neither changes original recorded vitals.").font(.footnote).foregroundStyle(Theme.text2)
                    Button("Review current evidence", systemImage: "arrow.clockwise") { Task { await model.prepareValidated(selection) } }
                        .disabled(!model.canStartMutation).accessibilityIdentifier("validated.review")
                    if model.busy { ProgressView("Checking current evidence…") }
                    if let review = model.validatedReview, review.request.selection == selection {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Evidence review passed").font(.headline)
                            Text("Profile generation \(review.request.expectedGeneration)")
                            Text("Core verifies this selection again when applying. A different report, candidate or generation requires another review.").font(.footnote).foregroundStyle(Theme.text2)
                            ForEach(review.diff.changes) { change in
                                DisclosureGroup(change.path) {
                                    BiometricProfileIdentity(title: "Before", value: change.before.formattedJSON)
                                    BiometricProfileIdentity(title: "After", value: change.after.formattedJSON)
                                }
                            }
                        }.cardStyle()
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Button("Apply evaluated revision") { Task { await model.applyValidated(boundary: boundary) } }
                            .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                            .disabled(!model.canApplyValidated || model.validatedReview?.request.selection != selection)
                            .accessibilityIdentifier("validated.apply")
                    }
                }
                BiometricProfilePendingCard(model: model)
            } else if error == nil { ProgressView("Loading profile…") }
        }.task {
            guard model == nil else { return }
            do {
                let store = APIBackend.current.isDemo ? BiometricProfilePendingStore(directory: nil) : try .persistent()
                let workspace = BiometricProfilesWorkspace(side: selection.side, client: client, pendingStore: store)
                model = workspace
                await workspace.prepareValidated(selection)
            } catch { self.error = error.localizedDescription }
        }.modifier(BiometricProfileObservation(model: model))
    }
}
