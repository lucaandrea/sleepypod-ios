import SwiftUI

struct CoachUsageView: View {
    @Environment(AppModel.self) private var model
    let revision: Int
    @State private var workspace = CoachUsageWorkspace()
    var body: some View {
        SleepCard(title: "Model usage", eyebrow: "YOUR REQUESTS, YOUR LIMIT") {
            Text("Shared across both bed sides and all models. Local calculations do not use this allowance.")
                .sleepText(.small).foregroundStyle(SleepTheme.secondary)
            if let usage = workspace.snapshot {
                Text("\(usage.attempts) of \(usage.monthlyLimit) requests used").sleepText(.cardTitle)
                Text("\(usage.period) · UTC calendar month · \(usage.remaining) remaining")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                if usage.remaining == 0 {
                    Text("Model requests are paused at this limit. Local calculations remain available.").sleepText(.small)
                }
                Text("\(usage.completed) completed · \(usage.failed) failed · \(usage.pending) in progress · \(usage.unresolved) unresolved")
                    .sleepText(.small)
                Text("\(usage.totalTokens.formatted()) reported tokens · usage available for \(usage.tokensReportedFor) of \(usage.attempts) requests")
                    .sleepText(.small)
                SleepFormField(title: "Monthly model request limit") {
                    TextField("Monthly model request limit", value: $workspace.limit, format: .number.grouping(.never))
                        .keyboardType(.numberPad).disabled(workspace.busy)
                }
                Text("0 pauses model requests. Choose a whole number up to 1000.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                HStack {
                    Button("Save limit") { Task { await save() } }.buttonStyle(SleepButtonStyle(kind: .primary))
                        .disabled(workspace.busy || !workspace.hasDraft || !workspace.valid)
                    Button("Reset draft") { workspace.reset() }.buttonStyle(SleepButtonStyle())
                        .disabled(workspace.busy || !workspace.hasDraft)
                }
                if let error = workspace.error { Text(error).sleepText(.small).foregroundStyle(SleepTheme.error) }
                if let message = workspace.message { Text(message).sleepText(.small).accessibilityAddTraits(.updatesFrequently) }
                ForEach(usage.providers) { provider in
                    Divider()
                    Text(provider.title).sleepText(.cardTitle)
                    Text(provider.models.joined(separator: ", ")).sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                    Text("\(provider.attempts) \(provider.attempts == 1 ? "request" : "requests") · \(provider.completed) completed · \(provider.failed) failed")
                        .sleepText(.small)
                    Text("\(provider.inputTokens.formatted()) input · \(provider.outputTokens.formatted()) output tokens").sleepText(.small)
                    Text("Usage available for \(provider.tokensReportedFor) of \(provider.attempts) requests · \(responseTime(provider))")
                        .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                }
            }
            if workspace.busy { ProgressView("Loading model usage…") }
            if workspace.snapshot == nil, let error = workspace.error { Text(error).sleepText(.small).foregroundStyle(SleepTheme.error) }
            Button("Refresh usage") { Task { await load() } }.buttonStyle(SleepButtonStyle()).disabled(workspace.busy)
            Text("Failed and unresolved attempts count toward the limit. Token totals include only reported usage and may be incomplete. This is a request limit, not a dollar spending cap; check your provider for charges.")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            Text("The usage log stores model names, counts and timing. Questions, answers and health records are not saved in it.")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
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
