import SwiftUI

struct PersonalLearningRemovalSection: View {
    let model: PersonalLearningWorkspace
    @FocusState private var removalFocused: Bool
    @AccessibilityFocusState private var removalAccessibilityFocused: Bool

    var body: some View {
        Group {
            if let removal = model.removal {
                Section {
                    Text(heading(removal.phase)).font(.headline).accessibilityIdentifier("learning.removalHeading")
                    Text(removal.title).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("learning.removalRecord")
                    if removal.phase == .removed, let receipt = removal.receipt {
                        Label("Confirmed by your Pod", systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.text1).accessibilityIdentifier("learning.removalConfirmed")
                        Text(PersonalLearningPresentation.date(receipt.removedAt)).font(.footnote).foregroundStyle(Theme.text2)
                    } else if removal.phase == .review {
                        Text("Only this archived copy on the Pod will be removed. Its source, date and preservation receipt remain.")
                    } else {
                        Text("The app will check the existing receipt. It will not send the removal again.")
                            .accessibilityIdentifier("learning.removalRecovery")
                    }
                    Text("Original records, active models and routines stay unchanged. Backups and files already exported are not erased.")
                        .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("learning.removalBoundary")
                    if removal.phase == .review {
                        Button(role: .destructive) { Task { await model.confirmRemoval() } } label: {
                            Text("Remove saved copy").foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                        }.disabled(model.busy).accessibilityIdentifier("learning.confirmRemoval")
                        Button { model.cancelRemoval() } label: {
                            Text("Keep saved copy").fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                        }.disabled(model.busy).accessibilityIdentifier("learning.cancelRemoval")
                    } else if removal.phase == .uncertain {
                        Button { Task { await model.checkRemovalReceipt() } } label: {
                            Text("Check removal receipt").fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                        }.disabled(model.busy).accessibilityIdentifier("learning.checkRemoval")
                    }
                }
            } else if model.removalAvailable, model.detail?.redacted == false {
                Section {
                    Button(role: .destructive) { model.reviewRemoval() } label: {
                        Text("Remove saved copy…").foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                    }
                    .disabled(model.busy).focused($removalFocused).accessibilityFocused($removalAccessibilityFocused)
                    .accessibilityIdentifier("learning.reviewRemoval")
                }
            }
        }
        .onChange(of: model.removal?.phase) { previous, current in
            if previous == .review, current == nil { removalFocused = true; removalAccessibilityFocused = true }
        }
    }
    private func heading(_ phase: PersonalLearningRemovalProgress.Phase) -> String {
        switch phase {
        case .review: "Remove this saved copy?"
        case .uncertain: "Check the removal result"
        case .removed: "Saved copy removed"
        }
    }
}
