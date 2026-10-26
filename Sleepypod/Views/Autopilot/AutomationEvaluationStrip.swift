import Charts
import SwiftUI

struct AutomationEvaluationStrip: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let now: Date
    private struct Evaluation: Identifiable {
        let id: Int
        let date: Date
        let run: AutomationDiagnostics.Run
    }
    private let evaluations: [Evaluation]
    private let sentToday: Int
    private let wouldFireToday: Int
    init(runs: [AutomationDiagnostics.Run], now: Date, startOfDay: Date?) {
        self.now = now
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        // Parse the potentially day-long log once; rendering the strip needs only the last three hours.
        let parsed = runs.enumerated().compactMap { index, run -> Evaluation? in
            guard let date = fractional.date(from: run.t) ?? standard.date(from: run.t), date <= now else { return nil }
            return Evaluation(id: index, date: date, run: run)
        }
        evaluations = parsed.filter { $0.date >= now.addingTimeInterval(-10800) }
        let today = parsed.filter { item in startOfDay.map { item.date >= $0 } ?? false }
        sentToday = today.filter { $0.run.sent }.count
        wouldFireToday = today.filter { $0.run.outcome == "dry_run" }.count
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 3 hours").font(.caption).foregroundStyle(Theme.text2)
            if evaluations.isEmpty { Text("No recorded evaluations.").font(.footnote).foregroundStyle(Theme.text2) }
            else {
                Chart(evaluations) { item in
                    PointMark(x: .value("Evaluation", item.date), y: .value("Run", 1))
                        .symbol(.square).symbolSize(36).foregroundStyle(color(item.run))
                        .accessibilityLabel(item.run.label)
                }.chartXScale(domain: now.addingTimeInterval(-10800)...now).chartYScale(domain: 0...2)
                    .chartXAxis {
                        AxisMarks(values: [now.addingTimeInterval(-10800), now]) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                    .chartYAxis(.hidden).frame(height: typeSize.isAccessibilitySize ? 120 : 44)
                    .accessibilityLabel("Evaluation history during the last three hours")
            }
            Text("Today · \(sentToday) sent to bed · \(wouldFireToday) would fire").font(.caption)
            Text("Green sent · gray skipped · amber missing or dry run · red error").font(.caption2).foregroundStyle(Theme.text2)
        }
    }
    private func color(_ run: AutomationDiagnostics.Run) -> Color {
        if run.sent { return Theme.green }
        if run.outcome == "error" { return Theme.red }
        if run.outcome == "dry_run" || run.reason == "condition-unknown" { return Theme.amber }
        return Theme.text2
    }
}
