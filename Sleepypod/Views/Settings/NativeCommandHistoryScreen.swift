import SwiftUI

struct NativeCommandHistoryScreen: View {
    @Environment(NativeActionSession.self) private var actions
    @State private var records: [NativeControlAttempt] = []
    @State private var error: String?
    @State private var loading: UUID?
    @State private var review: NativeControlAttempt?
    @AppStorage("ownerConnectionRevision") private var connectionRevision = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("podIPAddress") private var host = ""
    private var scope: String { [connectionRevision, backend, endpoint, host].joined(separator: "|") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if actions.historyExample { Eyebrow("SYNTHETIC COMMAND EXAMPLES", color: Theme.amber) }
                Text("Commands sent from Shortcuts are kept here. A controller acknowledgment does not confirm a physical change.")
                    .font(.subheadline).foregroundStyle(Theme.text2)
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.amber).accessibilityIdentifier("commandHistory.error") }
                if records.isEmpty {
                    ContentUnavailableView("No commands yet", systemImage: "clock.arrow.circlepath", description: Text("Your next Shortcut command will appear here."))
                }
                ForEach(records) { value in
                    Group {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(value.request.action.label).font(.headline)
                            Text(Date(timeIntervalSince1970: Double(value.request.issuedAt) / 1000), format: .dateTime.month().day().hour().minute())
                                .font(.caption.monospaced()).foregroundStyle(Theme.text2)
                            Eyebrow(stateLabel(value), color: value.needsReview ? Theme.amber : Theme.text2)
                            Text(value.receipt?.message ?? "No receipt was received. Refresh to check this command's existing ID. It will not be sent again.")
                                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            if let reviewedAt = value.reviewedAt {
                                Text("Reviewed \(reviewedAt.formatted(date: .abbreviated, time: .shortened)). This does not confirm the bed's state.")
                                    .font(.footnote).foregroundStyle(Theme.text2)
                            }
                            Button { refresh(value.id) } label: { Label("Refresh receipt", systemImage: "arrow.clockwise") }
                                .accessibilityIdentifier("commandHistory.refresh.\(value.request.action.kind)")
                                .disabled(loading != nil || (APIBackend.current != .sleepypodCore && !actions.historyExample))
                            if value.needsReview {
                                Button { review = value } label: { Label("Review uncertain result", systemImage: "checkmark.circle") }
                                    .accessibilityIdentifier("commandHistory.review.\(value.request.action.kind)")
                                    .disabled(loading != nil || (APIBackend.current != .sleepypodCore && !actions.historyExample))
                            }
                            Text("Request \(value.id.uuidString.lowercased())").font(.caption.monospaced()).foregroundStyle(Theme.text3).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.cardStyle()
                }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }
        .background(Theme.background).foregroundStyle(Theme.text1).tint(Theme.text1)
        .navigationTitle("Command history").navigationBarTitleDisplayMode(.inline)
        .task(id: scope) { review = nil; loading = nil; reload() }
        .confirmationDialog("Review command?", isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } }), titleVisibility: .visible) {
            Button("I checked the bed") {
                guard let value = review else { return }
                do { try actions.review(value.id); reload() } catch { self.error = APIError.message(for: error) }
                review = nil
            }
            Button("Cancel", role: .cancel) { review = nil }
        } message: {
            Text("Check the bed first. Review does not resend this command or confirm its outcome.")
        }
    }
    private func stateLabel(_ value: NativeControlAttempt) -> String {
        (value.receipt?.state ?? "No receipt").replacingOccurrences(of: "_", with: " ").uppercased()
    }
    private func reload() {
        do { records = try actions.history(); error = nil } catch { records = []; self.error = APIError.message(for: error) }
    }
    private func refresh(_ id: UUID) {
        let original = scope; loading = id; error = nil
        Task {
            do { try await actions.refresh(id); guard original == scope else { return }; reload() }
            catch { guard original == scope else { return }; self.error = APIError.message(for: error) }
            loading = nil
        }
    }
}
