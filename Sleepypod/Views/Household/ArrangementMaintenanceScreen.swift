import SwiftUI

/// Attended actions stay separate from account preparation and ordinary bed controls.
struct ArrangementMaintenanceScreen: View {
    @Bindable var model: ArrangementMaintenanceWorkspace
    var review: ArrangementReview?
    let refresh: () async -> Void
    let close: () -> Void

    var body: some View {
        Form {
            Section {
                Label(model.entered ? "Finish your side change" : "Attended side change", systemImage: "bed.double")
                    .font(.title2.bold()).accessibilityIdentifier("maintenance.title")
                Text("Stay beside the empty bed. Ordinary controls remain paused while a saved transition is unfinished.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if model.busy { ProgressView("Checking the controller…") }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("maintenance.error") }
                if let notice = model.notice { Text(notice).font(.footnote).accessibilityIdentifier("maintenance.notice") }
                Button("Check saved transition") { Task { await refresh() } }
                    .disabled(model.busy).accessibilityIdentifier("maintenance.refresh")
            }
            if model.loaded {
                if let operation = model.currentOperation { operationSections(operation) }
                if let review, model.canStart(review) {
                    Section("Approved sides") {
                        LabeledContent("Your proposed side", value: review.person.proposedSide.displayName)
                        LabeledContent("Partner’s proposed side", value: review.partner.proposedSide.displayName)
                        Text("Both people approved this review. The controller rechecks those approvals and the saved settings before changing the arrangement.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                    confirmations(.activate, title: "Before switching sides", button: "Switch to the approved sides") { await model.activate(review) }
                } else if model.currentOperation == nil {
                    Section { Text(model.entered
                        ? "No saved receipt is available yet. Keep checking the transition; the earlier action will not be repeated."
                        : "There is no unfinished side change. Both people must approve a shared side review before a separate activation becomes available.")
                        .accessibilityIdentifier("maintenance.empty") }
                }
            }
            Section {
                Button("Close personal session", action: close).accessibilityIdentifier("maintenance.signOut")
                Text("Closing does not cancel the transition or reopen bed controls. You can sign in again to check the saved result.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Bed arrangement").navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.confirmations = [] }
    }

    @ViewBuilder private func operationSections(_ operation: ArrangementMaintenanceStatus.Operation) -> some View {
        Section("Saved progress") {
            Label(operation.state.title, systemImage: operation.pending ? "pause.circle" : "checkmark.circle")
                .font(.headline).accessibilityIdentifier("maintenance.state")
            Text(operation.state.explanation).font(.footnote)
            LabeledContent("Controller restart", value: operation.controllerRestarted == true ? "New session verified" : "Not yet verified")
            LabeledContent("Bed controls", value: operation.admission == .open ? "Server allows commands" : "Paused or unavailable")
            Text("A server receipt confirms saved software state. It does not prove physical temperature, vibration or movement.")
                .font(.footnote).foregroundStyle(Theme.text2)
        }
        if operation.pending, operation.admission == .thisTransition {
            if operation.controllerRestarted == false, operation.restart == nil {
                confirmations(.restart, title: "Restart the controller", button: "Request one controller restart") { await model.restart() }
            } else if operation.controllerRestarted != true {
                Section("Waiting for a new controller session") {
                    Text("Reconnect and check the saved transition. A saved restart request is never sent again, even if its reply was lost.")
                }
            }
            if operation.controllerRestarted == true {
                if operation.state == .committed {
                    confirmations(.recover, title: "Finish and verify the assigned sides", button: "Finish recovery") { await model.recover() }
                } else if operation.state == .held {
                    Section("Keep the current solo arrangement") {
                        Text("No side change was committed. Review the saved control state before allowing the existing routines to resume.").font(.footnote)
                        Button("Review keeping solo") { Task { await model.previewCancellation() } }
                            .disabled(model.busy).accessibilityIdentifier("maintenance.previewCancel")
                    }
                    if model.cancellation != nil {
                        confirmations(.cancel, title: "Confirm keeping solo", button: "Keep solo and finish recovery") { await model.cancel() }
                    }
                }
            }
        } else if !operation.pending, operation.admission == .open {
            Section {
                Button("Reload my assigned controls") { Task { await model.returnToControls() } }
                    .disabled(model.busy).accessibilityIdentifier("maintenance.return")
                Text("A fresh check reloads your current account assignment. Old controls and drafts are not reused.").font(.footnote)
            }
        }
    }

    private func confirmations(_ action: ArrangementMaintenanceRequest.Action, title: String, button: String, perform: @escaping () async -> Void) -> some View {
        Section(title) {
            ForEach(action.confirmations.sorted(), id: \.self) { field in
                Toggle(ArrangementMaintenanceCopy.confirmation(field), isOn: Binding(
                    get: { model.confirmations.contains(field) },
                    set: { if $0 { model.confirmations.insert(field) } else { model.confirmations.remove(field) } }
                )).accessibilityIdentifier("maintenance.confirm.\(field)")
            }
            Button(button) { Task { await perform() } }
                .disabled(!model.confirmed(action)).accessibilityIdentifier("maintenance.\(action.rawValue)")
        }.disabled(model.busy || !model.enabled)
    }
}

private enum ArrangementMaintenanceCopy {
    static func confirmation(_ field: String) -> String {
        switch field {
        case "confirmEmptyAndAttended": "The bed is empty, the cover is connected, the reservoir is filled, and I am nearby"
        case "confirmClearTemporaryActions": "Clear temporary temperature actions and old overrides"
        case "confirmPauseLearningAndSharedAutomations": "Keep learning and shared automations paused"
        case "acknowledgeHeldUntilRecovery": "Keep controls paused until restart and recovery are checked"
        case "acknowledgeConnectionWillClose": "The connection will close during the restart"
        case "acknowledgeControlsRemainPaused": "Bed controls stay paused after restarting"
        case "confirmAssignedSides": "I checked the assigned sides with my partner"
        case "acknowledgeRecordingGap": "Recordings will show a gap during maintenance"
        case "acknowledgeLearningRemainsOff": "Personal learning stays off until separately reviewed"
        case "confirmKeepSoloArrangement": "Keep the current solo bed arrangement"
        case "acknowledgeSavedRoutinesMayResume": "The saved routines may resume after recovery"
        default: "Review this required confirmation"
        }
    }
}

private extension ArrangementMaintenanceStatus.Operation.State {
    var title: String {
        switch self {
        case .held: "Controls paused · sides unchanged"
        case .committed: "Side assignments saved · recovery needed"
        case .completed: "Recovery recorded"
        case .cancelled: "Solo arrangement preserved"
        }
    }
    var explanation: String {
        switch self {
        case .held: "The controller paused commands before changing sides. A verified restart is required before keeping the solo arrangement."
        case .committed: "The approved assignments are saved. Verify a new controller session, then finish the attended recovery."
        case .completed: "The controller recorded the recovery. Check the saved result and reload current controls explicitly."
        case .cancelled: "The controller recorded keeping the solo arrangement. Check the saved result before returning to controls."
        }
    }
}
