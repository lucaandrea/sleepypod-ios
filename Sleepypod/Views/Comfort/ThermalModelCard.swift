import SwiftUI

/// Training is an explicit Pod operation; displaying readiness does not fit or activate a model.
struct ThermalModelCard: View {
    let side: Side
    let client: any PersonalComfortClient
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var status: ThermalModelStatus?
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var operation = UUID()
    @AppStorage("ownerConnectionRevision") private var owner = ""
    private var scope: String { "\(owner)|\(side.rawValue)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your temperature model", systemImage: "brain").font(.headline)
            Text("Trains locally on your Pod").font(.caption.weight(.medium)).foregroundStyle(Theme.cool)
                .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.cool.opacity(0.12), in: .capsule)
            Text("Learns your morning comfort feedback from complete nights of bed and room readings. Sleep-stage models are separate.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            if let status {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                    metric("Complete reviewed nights", "\(status.completeNights) / \(status.requiredNights)", color: Theme.cool)
                    metric("Morning check-ins", "\(status.feedbackNights)", color: Theme.green)
                    metric("Model status", status.model.map { $0.current ? "Saved · Preview" : "Needs recheck" } ?? "Collecting", color: Theme.amber)
                }
                Text(status.reason).font(.footnote).foregroundStyle(Theme.text2)
                if let model = status.model {
                    DisclosureGroup("Validation on unseen nights") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(model.trainingDates.count) earlier nights fitted · \(model.validationDates.count) later nights held out.")
                            ComfortValueRow("Model error", value: model.validation.modelMae.formatted(.number.precision(.fractionLength(2))))
                            ComfortValueRow("Hold temperature", value: model.validation.holdMae.formatted(.number.precision(.fractionLength(2))))
                            ComfortValueRow("Average feedback", value: model.validation.averageMae.formatted(.number.precision(.fractionLength(2))))
                            Text("Lower is better. These are feedback-direction scores, not ideal temperatures.")
                            Text(model.validation.reason)
                        }.font(.footnote).padding(.top, 8)
                    }
                }
                if !status.excluded.isEmpty {
                    DisclosureGroup("Why \(status.excluded.count) nights were excluded") {
                        ForEach(status.excluded) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.date).font(.subheadline.bold())
                                Text(item.reason).font(.footnote).foregroundStyle(Theme.text2)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                        }
                    }
                }
                Button(busy ? "Working on Pod…" : "Train temperature model") { Task { await refresh(train: true) } }
                    .buttonStyle(CapsuleButtonStyle(weight: .filled))
                    .disabled(busy || !status.canTrain || error != nil || APIBackend.current.isDemo)
                    .accessibilityIdentifier("thermalModel.train")
            }
            if busy { ProgressView("Checking Pod model…") }
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            if let notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
            Button("Check nights again", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .disabled(busy).accessibilityIdentifier("thermalModel.refresh")
            Text("Only reviewed 6–12 hour nights with at least 90% thermal coverage qualify. Partial recordings and wake warming are excluded. Fitting never changes temperature or activates Autopilot.")
                .font(.footnote).foregroundStyle(Theme.text2)
        }.cardStyle().accessibilityElement(children: .contain).accessibilityIdentifier("thermalModel.card")
            .task(id: scope) { status = nil; await refresh() }
            .onDisappear { operation = UUID(); busy = false }
    }

    private func metric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            Text(value).font(.headline).foregroundStyle(color)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(14)
            .background(color.opacity(0.1), in: .rect(cornerRadius: 14))
            .accessibilityElement(children: .combine)
    }

    private func refresh(train: Bool = false) async {
        let request = UUID(), original = scope, hash = status?.datasetHash
        operation = request; busy = true; error = nil; notice = nil
        defer { if operation == request { busy = false } }
        do {
            let value: ThermalModelStatus
            if train, let hash { value = try await client.trainThermalModel(side: side, datasetHash: hash) }
            else { value = try await client.thermalModel(side: side) }
            guard request == operation, original == scope, !Task.isCancelled else { return }
            guard value.apiVersion == 1, value.side == side else { throw APIError.serverError(message: "The model response does not match this side.") }
            status = value
            if train { notice = "Model saved on your Pod. Temperature control remains unchanged." }
        } catch {
            guard request == operation, original == scope, !Task.isCancelled else { return }
            self.error = APIError.message(for: error)
        }
    }
}
