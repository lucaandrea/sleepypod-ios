import SwiftUI

struct DatasetReferencePickerScreen: View {
    let client: any BiometricDatasetsServing
    let draft: BiometricDatasetDraft
    @State private var page: ReferenceLibraryPage?
    @State private var cursor: ReferenceLibraryPage.Cursor?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                BiometricProfileValue("Sleeper identifier", value: draft.selection.subjectId.isEmpty ? "Enter an identifier in Evaluation inputs" : draft.selection.subjectId)
                Text("\(draft.selectedReferences.count) / 20 reference revisions selected").font(.headline)
                Text("Choose available references for this side and sleeper. Select one revision from each source family.").font(.footnote).foregroundStyle(Theme.text2)
                if !draft.selectedReferences.isEmpty {
                    DisclosureGroup("Selected references") {
                        ForEach(draft.selectedReferences.values.sorted { $0.id < $1.id }) { reference in
                            Button("Remove \(reference.summary.source) · revision \(reference.revision)", role: .destructive) { draft.removeReference(reference.id) }
                        }
                    }.cardStyle()
                }
                if let error { BiometricProfileError(error: error) }
                if loading { ProgressView("Loading references…") }
                Button("Reload references", systemImage: "arrow.clockwise") { Task { await load(cursor) } }.disabled(loading)
                if let page {
                    if page.items.isEmpty { Text("No reference imports for this side.").foregroundStyle(Theme.text2) }
                    ForEach(page.items) { reference in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(reference.summary.source) · revision \(reference.revision)").font(.headline)
                            Text(reference.summary.subjectId)
                            Text("\(reference.summary.accepted) accepted · \(reference.summary.unscorable) excluded from scoring").font(.footnote).foregroundStyle(Theme.text2)
                            if draft.selectedReferences[reference.id] != nil {
                                Button("Remove reference", role: .destructive) { draft.removeReference(reference.id) }.accessibilityIdentifier("datasets.removeReference")
                            } else {
                                if let reason = draft.referenceReason(reference) { Text(reason).font(.footnote).foregroundStyle(Theme.text2) }
                                Button("Include reference") { do { try draft.include(reference) } catch { self.error = error.localizedDescription } }
                                    .disabled(draft.referenceReason(reference) != nil || loading || error != nil).accessibilityIdentifier("datasets.includeReference")
                            }
                            DisclosureGroup("Reference identity") {
                                BiometricProfileIdentity(title: "Revision", value: reference.id)
                                BiometricProfileIdentity(title: "Content hash", value: reference.summary.contentHash)
                            }
                        }.cardStyle()
                    }
                    if cursor != nil { Button("Newest imports") { Task { await load(nil) } }.disabled(loading) }
                    if let next = page.nextCursor { Button("Older imports") { Task { await load(next) } }.disabled(loading) }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Reference revisions").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("datasets.referencesContent")
            .task(id: draft.selection.subjectId) { page = nil; await load(nil) }
    }
    private func load(_ next: ReferenceLibraryPage.Cursor?) async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await client.references(side: draft.side, cursor: next)
            guard !Task.isCancelled else { return }
            guard result.items.allSatisfy({ $0.summary.side == draft.side }) else { throw BiometricBacktestInput.error("These references do not match the selected side.") }
            page = result; cursor = next
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
