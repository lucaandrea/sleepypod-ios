import SwiftUI

extension HealthCheckStatus {
    var color: Color {
        switch self {
        case .ok: Theme.green
        case .idle: Theme.text3
        case .stale: Theme.amber
        case .down: Theme.red
        case .unknown: Theme.border2
        }
    }
}

struct SystemHealthHistoryView: View {
    let history: SystemHealthHistory
    @State private var allChecks = false
    @State private var allIncidents = false
    @State private var position = 1.0
    private var selected: Double { history.from + max(0, history.to - history.from) * position }
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Last 24 hours").font(.headline)
                Text("Each check is sampled once a minute.").font(.footnote).foregroundStyle(Theme.text2)
                if let start = history.recordedSince { Text("Recording started \(clock(start))").font(.caption).foregroundStyle(Theme.text2) }
                if history.checks.isEmpty { Text("No health checks have been recorded.").foregroundStyle(Theme.text2) }
                ForEach(history.rows(all: allChecks)) { row in historyRow(row) }
                if !history.checks.isEmpty {
                    Text("Inspect \(clock(selected))").font(.footnote.monospacedDigit()).accessibilityIdentifier("health.history.time")
                    Slider(value: $position, in: 0...1).accessibilityLabel("Inspect health history").accessibilityValue(clock(selected))
                    Text("\(clock(history.from)) → \(clock(history.to))").font(.caption).foregroundStyle(Theme.text2)
                    Button(allChecks ? "Show fewer checks" : "Show all \(history.checks.count) checks") { allChecks.toggle() }.accessibilityIdentifier("health.history.all")
                }
                Text("Green: flowing · Gray: idle · Amber: stalled · Red: down · Unfilled: not recorded").font(.caption).foregroundStyle(Theme.text2)
                Divider()
                Text("Incidents").font(.headline)
                let incidents = history.incidentLines
                if incidents.isEmpty { Text("No incidents in the recorded period.").font(.footnote).foregroundStyle(Theme.text2) }
                ForEach(allIncidents ? incidents : Array(incidents.prefix(3))) { incident in
                    VStack(alignment: .leading, spacing: 6) {
                        Label { Text(incident.title).font(.subheadline.weight(.semibold)) } icon: { Circle().fill(incident.status.color).frame(width: 8, height: 8) }
                        Text("\(clock(incident.start)) → \(incident.end.map(clock) ?? "now")").font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
                        if let tag = incident.tag { Text(tag).font(.caption.weight(.semibold)).foregroundStyle(incident.status.color) }
                        if let detail = incident.detail { Text(detail).font(.footnote).foregroundStyle(Theme.text2) }
                    }.padding(.vertical, 4)
                }
                if incidents.count > 3 { Button(allIncidents ? "Show fewer incidents" : "Show \(incidents.count - 3) earlier incidents") { allIncidents.toggle() } }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func clock(_ time: Double) -> String { SystemHealthPath.date(time).formatted(date: .abbreviated, time: .shortened) }
    private func historyRow(_ row: SystemHealthHistory.Row) -> some View {
        let reading = row.runs.first { $0.start <= selected && ($0.end > selected || selected == history.to && $0.end == selected) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(row.label).font(.subheadline)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.active)
                    if history.to > history.from {
                        ForEach(Array(row.runs.enumerated()), id: \.offset) { _, run in
                            let left = min(1, max(0, (run.start - history.from) / (history.to - history.from)))
                            let right = min(1, max(0, (run.end - history.from) / (history.to - history.from)))
                            Rectangle().fill(run.status.color).frame(width: max(0, (right - left) * geometry.size.width)).offset(x: left * geometry.size.width)
                        }
                    }
                    Rectangle().fill(Theme.text1).frame(width: 2).offset(x: min(geometry.size.width - 2, max(0, position * geometry.size.width)))
                }.clipShape(RoundedRectangle(cornerRadius: 3))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in position = min(1, max(0, value.location.x / max(1, geometry.size.width))) })
            }.frame(height: 18).accessibilityHidden(true)
            Text(reading.map { "\($0.status.title) · \(clock($0.start)) → \(clock($0.end))" } ?? "Not recorded at the selected time")
                .font(.caption).foregroundStyle(reading?.status.color ?? Theme.text2).accessibilityIdentifier("health.history.reading.\(row.id)")
            Text(row.incidents > 0 ? "\(row.incidents) \(row.incidents == 1 ? "incident" : "incidents")" : row.healthyShare.map { "\(Int(min(1, max(0, $0)) * 100))% healthy during recorded time" } ?? "Healthy share unknown")
                .font(.caption).foregroundStyle(Theme.text2)
        }
    }
}
