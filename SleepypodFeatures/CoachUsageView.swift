import SwiftUI

struct CoachUsageView: View {
    @Environment(AppModel.self) private var model
    let revision: Int
    @State private var workspace = CoachUsageWorkspace()
    var body: some View {
        FeatureSection(title: "Model usage", eyebrow: "YOUR REQUESTS, YOUR LIMIT") {
            Text("Shared across both bed sides and all models. Local calculations do not use this allowance.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            if let usage = workspace.snapshot {
                Text("\(usage.attempts) of \(usage.monthlyLimit) requests used").font(.headline)
                Text("\(usage.period) · UTC calendar month · \(usage.remaining) remaining")
                    .font(.caption).foregroundStyle(Theme.text2)
                if usage.remaining == 0 {
                    Text("Model requests are paused at this limit. Local calculations remain available.").font(.subheadline)
                }
                Text("\(usage.completed) completed · \(usage.failed) failed · \(usage.pending) in progress · \(usage.unresolved) unresolved")
                    .font(.subheadline)
                Text("\(usage.totalTokens.formatted()) reported tokens · usage available for \(usage.tokensReportedFor) of \(usage.attempts) requests")
                    .font(.subheadline)
                FeatureField(title: "Monthly model request limit") {
                    TextField("Monthly model request limit", value: $workspace.limit, format: .number.grouping(.never))
                        .keyboardType(.numberPad).disabled(workspace.busy)
                }
                Text("0 pauses model requests. Choose a whole number up to 1000.").font(.caption).foregroundStyle(Theme.text2)
                HStack {
                    Button("Save limit") { Task { await save() } }.buttonStyle(PrimaryButtonStyle())
                        .disabled(workspace.busy || !workspace.hasDraft || !workspace.valid)
                    Button("Reset draft") { workspace.reset() }.buttonStyle(GlassButtonStyle())
                        .disabled(workspace.busy || !workspace.hasDraft)
                }
                if let error = workspace.error { Text(error).font(.subheadline).foregroundStyle(Theme.red) }
                if let message = workspace.message { Text(message).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
                ForEach(usage.providers) { provider in
                    Divider()
                    Text(provider.title).font(.headline)
                    Text(provider.models.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.text2)
                    Text("\(provider.attempts) \(provider.attempts == 1 ? "request" : "requests") · \(provider.completed) completed · \(provider.failed) failed")
                        .font(.subheadline)
                    Text("\(provider.inputTokens.formatted()) input · \(provider.outputTokens.formatted()) output tokens").font(.subheadline)
                    Text("Usage available for \(provider.tokensReportedFor) of \(provider.attempts) requests · \(responseTime(provider))")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
            }
            if workspace.busy { ProgressView("Loading model usage…") }
            if workspace.snapshot == nil, let error = workspace.error { Text(error).font(.subheadline).foregroundStyle(Theme.red) }
            Button("Refresh usage") { Task { await load() } }.buttonStyle(GlassButtonStyle()).disabled(workspace.busy)
            Text("Failed and unresolved attempts count toward the limit. Token totals include only reported usage and may be incomplete. This is a request limit, not a dollar spending cap; check your provider for charges.")
                .font(.caption).foregroundStyle(Theme.text2)
            Text("The usage log stores model names, counts and timing. Questions, answers and health records are not saved in it.")
                .font(.caption).foregroundStyle(Theme.text2)
        }.task(id: revision) { await load() }.onDisappear { workspace.invalidate() }
    }
    private func responseTime(_ provider: CoachUsage.Provider) -> String {
        guard let duration = provider.averageResponseMilliseconds else { return "Response time unavailable" }
        let seconds = Double((duration + 50) / 100) / 10
        return "\(seconds.formatted(.number.precision(.fractionLength(1))))s average response"
    }
    private func load() async {
        await workspace.load {
            if model.demo { return try model.demoCoachUsage.read() }
            return try await PodClient.configured().get("ai/usage")
        }
    }
    private func save() async {
        await workspace.save { change in
            if model.demo { return try model.demoCoachUsage.save(change) }
            return try await PodClient.configured().postReturning("ai/usage/limit", body: change)
        }
    }
}
