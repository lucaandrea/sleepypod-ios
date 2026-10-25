import SwiftUI

struct HealthHistoryCard: View {
    @Bindable var workspace: IntelligenceWorkspace
    @State private var confirmForget = false
    var body: some View {
        SleepCard(title: "A history that’s yours", eyebrow: "APPLE HEALTH") {
            Text("Read all accessible sleep history, plus daily resting heart rate, HRV and respiration. Sources stay separate; only your selected source is used for sleep analysis.")
                .foregroundStyle(SleepTheme.secondary)
            Button(workspace.archive.history.sources.isEmpty ? "Connect & read Health history" : "Refresh Health history") {
                Task { await workspace.importHistory() }
            }.buttonStyle(SleepButtonStyle(kind: .primary)).disabled(workspace.busy || AppMode.isDemo)
            if !workspace.archive.history.sources.isEmpty {
                SleepFormField(title: "Your sleep source") {
                    Picker("Your sleep source", selection: $workspace.selectedSource) {
                        ForEach(workspace.archive.history.sources) { source in Text("\(source.name) · \(source.nights.count) days").tag(source.id) }
                    }.pickerStyle(.menu).labelsHidden()
                }.disabled(workspace.busy)
                Text("Last refreshed \(workspace.archive.history.importedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                Toggle("Refresh history when I open Free Sleep", isOn: $workspace.refreshHistory).toggleStyle(SleepCheckboxStyle())
                Text("New records update your baseline at most once every six hours while the app is open. This does not generate or send cloud reports automatically.")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                ForEach(workspace.facts) { fact in Text(fact.text).sleepText(.small) }
                Text("Daily vital averages can include readings from multiple Health sources and are not restricted to sleep. Earlier records are retained; recent patterns use the last 28 days.")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                Button("Forget imported history and reports") { confirmForget = true }
                    .buttonStyle(SleepButtonStyle(kind: .text)).disabled(workspace.busy)
            }
            Text("Read access is private in Health. Empty results can mean no records or no permission. You can change access in Apple Health at any time.")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        }.confirmationDialog("Remove Free Sleep’s local copy of your history and reports?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget local history", role: .destructive, action: workspace.forgetHistory)
        } message: { Text("Your original Apple Health records remain in Health.") }
    }
}
