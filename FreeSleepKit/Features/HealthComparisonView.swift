import SwiftUI

struct HealthComparisonView: View {
    let comparison: HealthComparison
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("From Apple Health").font(.headline)
            Text("Other sources · past 24 hours").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            if let minutes = comparison.asleepMinutes {
                LabeledContent("Time asleep", value: SleepAnalytics.duration(minutes))
                Text(comparison.sleepSources.joined(separator: ", ")).sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            } else { Text("No sleep readings available.").sleepText(.body).foregroundStyle(SleepTheme.secondary) }
            if let reading = comparison.heartRate { quantity("Heart rate", reading: reading, unit: "bpm") }
            if let reading = comparison.hrv { quantity("HRV · SDNN", reading: reading, unit: "ms") }
            if let reading = comparison.respiratoryRate { quantity("Breathing", reading: reading, unit: "/ min") }
            Text("Updated \(comparison.through.formatted(date: .abbreviated, time: .shortened))")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        }
    }
    private func quantity(_ title: String, reading: HealthComparison.Quantity, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title, value: "\(reading.value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
            Text("\(reading.source) · \(reading.at.formatted(date: .omitted, time: .shortened))")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        }
    }
}
