import SwiftUI

struct HealthHistoryCard: View {
    @Bindable var workspace: IntelligenceWorkspace
    @State private var confirmForget = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var selected: HealthHistory.Source? { workspace.archive.history.sources.first { $0.id == workspace.selectedSource } }
    private var recent: [HealthHistory.Night] { selected?.nights.filter { $0.end > Date().addingTimeInterval(-28 * 86400) } ?? [] }
    var body: some View {
        FeatureSection(title: "Health history", eyebrow: "APPLE HEALTH") {
            Text("Read all accessible sleep history, plus daily resting heart rate, HRV and respiration. Sources stay separate; only your selected source is used for sleep analysis.")
                .foregroundStyle(Theme.text2)
            Button(workspace.archive.history.sources.isEmpty ? "Connect & read Health history" : "Refresh Health history") {
                Task { await workspace.importHistory() }
            }.buttonStyle(PrimaryButtonStyle()).disabled(workspace.busy || AppMode.isDemo)
            if !workspace.archive.history.sources.isEmpty {
                FeatureField(title: "Your sleep source") {
                    Picker("Your sleep source", selection: $workspace.selectedSource) {
                        ForEach(workspace.archive.history.sources) { source in Text("\(source.name) · \(source.nights.count) days").tag(source.id) }
                    }.pickerStyle(.menu).labelsHidden()
                }.disabled(workspace.busy)
                Text("Last refreshed \(workspace.archive.history.importedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption).foregroundStyle(Theme.text2)
                Toggle("Refresh history when I open sleepypod", isOn: $workspace.refreshHistory).tint(Theme.green)
                Text("New records update your baseline at most once every six hours while the app is open. This does not generate or send cloud reports automatically.")
                    .font(.caption).foregroundStyle(Theme.text2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                    historyMetric("Recorded days", value: (selected?.nights.count ?? 0).formatted(), symbol: "calendar", color: Theme.cool)
                    historyMetric("Last 28 days", value: recent.count.formatted(), symbol: "moon.stars", color: Theme.green)
                    if recent.count >= 3, let minutes = HealthHistoryAnalyzer.median(recent.map(\.asleepMinutes)) {
                        historyMetric("Median recorded sleep", value: "\(Int(minutes) / 60)h \(Int(minutes) % 60)m", symbol: "bed.double", color: Theme.cool)
                    }
                    historyMetric("Training coverage", value: "Needs matching signals", symbol: "waveform.path", color: Theme.amber)
                }.accessibilityIdentifier("history.metrics")
                Text("A recorded day can include partial sleep or naps. These totals are useful history, not a count of complete training nights.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                DisclosureGroup("Source details & calculations") {
                    ForEach(workspace.facts) { fact in
                        Text(fact.text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                }
                Text("Daily vital averages can include readings from multiple Health sources and are not restricted to sleep. Earlier records are retained; recent patterns use the last 28 days.")
                    .font(.caption).foregroundStyle(Theme.text2)
                Button("Forget imported history and reports") { confirmForget = true }
                    .buttonStyle(GlassButtonStyle()).disabled(workspace.busy)
            }
            Text("Read access is private in Health. Empty results can mean no records or no permission. You can change access in Apple Health at any time.")
                .font(.caption).foregroundStyle(Theme.text2)
        }.confirmationDialog("Remove sleepypod’s local copy of your history and reports?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget local history", role: .destructive, action: workspace.forgetHistory)
        } message: { Text("Your original Apple Health records remain in Health.") }
    }

    private func historyMetric(_ title: String, value: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(Theme.text2)
            Text(value).font(.headline).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14).background(color.opacity(0.09), in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .combine)
    }
}
