import SwiftUI

struct PredictiveTargetSection: View {
    let workspace: PredictiveTargetWorkspace
    @Environment(SettingsManager.self) private var settings
    private var celsius: Bool { settings.temperatureFormat == .celsius }
    @State private var expanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 16) {
                Text("Compare a small change with holding").font(.headline)
                Text("Check whether a nearby target could track your bounded overnight plan more closely. This compares water estimates for the next 15 and 30 minutes. Your bed keeps following its current plan.")
                    .foregroundStyle(Theme.text2)
                Button {
                    Task { await workspace.refresh() }
                } label: {
                    Text(workspace.busy ? "Comparing current readings…" : workspace.requested ? "Refresh target comparison" : "Compare with holding")
                        .frame(minHeight: 44)
                }.buttonStyle(.bordered).disabled(workspace.busy).accessibilityIdentifier("predictive.refresh")
                if let result = workspace.preview(at: .now) {
                    Text(title(result)).font(.headline).accessibilityIdentifier("predictive.choice")
                    Text(result.reason).foregroundStyle(Theme.text2)
                    if let objective = result.desiredWaterF { Text("Tracking objective: \(temperature(objective)) water, within your overnight limits.").font(.subheadline) }
                    if !result.comparisons.isEmpty {
                        Button { expanded.toggle() } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text("See the alternatives and their uncertainty").fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 12)
                                Image(systemName: expanded ? "chevron.down" : "chevron.right").accessibilityHidden(true)
                            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityValue(expanded ? "Expanded" : "Collapsed").accessibilityIdentifier("predictive.alternatives")
                        if expanded {
                            ForEach(result.comparisons) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    Divider()
                                    Text("\(item.kind == .hold ? "Hold" : "Target") \(temperature(item.targetF)) · \(item.targetF == result.proposedTargetF ? "Research choice" : "Alternative")")
                                        .font(.subheadline.bold()).accessibilityIdentifier("predictive.target.\(Int(item.targetF))")
                                    ForEach(item.predictions) { prediction in
                                        Text("\(prediction.minutes) min: \(temperature(prediction.lowerF))–\(temperature(prediction.upperF)) water")
                                            .font(.subheadline).monospacedDigit().foregroundStyle(Theme.text2)
                                    }
                                    if item.predictions.isEmpty { Text(item.reason).foregroundStyle(Theme.text2) }
                                }
                            }
                        }
                    }
                    Text("A change must beat holding at both horizons after accounting for prediction error and a cost for changing. These are conditional estimates, not proof of better comfort. No adjustment was sent.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                } else if let error = workspace.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Theme.text2).accessibilityIdentifier("predictive.error")
                } else if workspace.requested && !workspace.busy {
                    Text("This comparison has expired. Refresh to use current readings.").foregroundStyle(Theme.text2).accessibilityIdentifier("predictive.expired")
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
    private func title(_ result: PredictiveTargetPreview) -> String {
        if result.disposition == .candidate, let target = result.proposedTargetF { return "\(temperature(target)) is an experiment candidate" }
        if result.disposition == .hold, let target = result.currentTargetF { return "Keep \(temperature(target)) in this comparison" }
        return "A comparison is not ready yet"
    }
    private func temperature(_ value: Double) -> String { TargetResponseTemperature.text(value, celsius: celsius) }
}
