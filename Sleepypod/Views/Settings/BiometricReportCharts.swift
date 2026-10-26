import SwiftUI
import Charts

struct BiometricStageTraceChart: View {
    let page: BiometricStageTracePage
    @ScaledMetric(relativeTo: .body) private var height = 220
    var body: some View {
        Chart {
            ForEach(Array(page.items.enumerated()), id: \.offset) { _, row in
                RuleMark(xStart: .value("Start", Date(timeIntervalSince1970: row.startMs / 1000)), xEnd: .value("End", Date(timeIntervalSince1970: row.endMs / 1000)), y: .value("Stage", row.stage.title))
                    .foregroundStyle(Theme.cool).lineStyle(StrokeStyle(lineWidth: 5))
            }
        }.chartYScale(domain: ["Wake", "REM", "Light", "Deep"]).modifier(ReportTimeAxis()).frame(height: min(height, 360))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel("Original replay intervals for this page. Gaps are left empty. Exact timestamps and stages follow below.")
    }
}
struct BiometricNumericTraceChart: View {
    let items: [BiometricNumericTracePage.Item]
    let metric: BiometricReportMetric
    @ScaledMetric(relativeTo: .body) private var height = 220
    var body: some View {
        Chart {
            ForEach(Array(items.enumerated()), id: \.offset) { _, row in
                if let value = row.value(metric) { PointMark(x: .value("Time", Date(timeIntervalSince1970: row.timestampMs / 1000)), y: .value(metric.unit, value)).foregroundStyle(Theme.cool) }
            }
        }.modifier(ReportTimeAxis()).frame(height: min(height, 360))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel("Recomputed \(metric.title) for this page. Each dot is one reading; missing values and gaps are not interpolated.")
    }
}
struct BiometricReferenceOverlayChart: View {
    let items: [BiometricNumericTracePage.Item]
    let metric: BiometricReportMetric
    let references: BiometricReferenceTracePage
    @ScaledMetric(relativeTo: .body) private var height = 240
    var body: some View {
        Chart {
            ForEach(Array(items.enumerated()), id: \.offset) { _, row in
                if let value = row.value(metric) {
                    PointMark(x: .value("Time", Date(timeIntervalSince1970: (row.timestampMs + Double(references.clockOffsetMs)) / 1000)), y: .value(metric.unit, value))
                        .foregroundStyle(Theme.cool).symbol(.circle)
                }
            }
            ForEach(Array(references.items.enumerated()), id: \.offset) { _, row in
                if row.compatibility == nil, let value = row.value {
                    if row.temporalKind == "point" {
                        PointMark(x: .value("Reference time", Date(timeIntervalSince1970: row.startMs / 1000)), y: .value(metric.unit, value)).foregroundStyle(Theme.amber).symbol(.square)
                    } else {
                        RuleMark(xStart: .value("Reference start", Date(timeIntervalSince1970: row.startMs / 1000)), xEnd: .value("Reference end", Date(timeIntervalSince1970: row.endMs / 1000)), y: .value(metric.unit, value))
                            .foregroundStyle(Theme.amber).lineStyle(StrokeStyle(lineWidth: 3))
                    }
                }
            }
        }.modifier(ReportTimeAxis()).frame(height: min(height, 380))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel("Displayed recomputed readings with compatible frozen references. Circles are readings, squares are reference points and bars are reference intervals.")
    }
}
struct ReportTimeAxis: ViewModifier {
    @Environment(SettingsManager.self) private var settings
    @AppStorage("podTimeFormat") private var timeFormat = "12h"
    func body(content: Content) -> some View {
        content.chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(); AxisTick()
                AxisValueLabel { if let date = value.as(Date.self) { Text(clock(date)) } }
            }
        }
    }
    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = DevicePreferences.clockLocale(format: timeFormat)
        formatter.timeZone = TimeZone(identifier: settings.timeZone) ?? TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate(timeFormat == "24h" ? "HHmm" : "hmm")
        return formatter.string(from: date)
    }
}
struct BiometricReportTimestamp: View {
    @Environment(SettingsManager.self) private var settings
    @AppStorage("podTimeFormat") private var timeFormat = "12h"
    let title: String
    let milliseconds: Double
    var body: some View { BiometricProfileValue(title, value: formatted) }
    private var formatted: String {
        let formatter = DateFormatter(); formatter.locale = DevicePreferences.clockLocale(format: timeFormat)
        formatter.timeZone = TimeZone(identifier: settings.timeZone) ?? TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate(timeFormat == "24h" ? "yMMMdHHmmssSSS" : "yMMMdhmmssSSS")
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}
