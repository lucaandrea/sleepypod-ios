import SwiftUI

struct BiometricSessionsCard: View {
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var limit = 40
    let sessions: [BiometricSession]
    let movement: [MovementBucket]
    let reference: WatchReferenceData
    let live: BiometricsLiveStatus?
    let side: Side
    let window: DateInterval
    let select: (BiometricSession) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sessions · \(sessions.count)").font(.headline).accessibilityIdentifier("biometrics.sessions")
            Text("Readings separated by more than 30 minutes or a change in measurement method form separate sessions.")
                .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if sessions.isEmpty { Text("No Pod sessions in this range").font(.footnote).foregroundStyle(Theme.text2) }
            ForEach(Array(sessions.reversed().prefix(limit).enumerated()), id: \.element.id) { index, session in
                row(session, index: index)
                if session.id != sessions.first?.id { Divider() }
            }
            if sessions.count > limit { Button("Show 40 more sessions") { limit += 40 } }
        }.cardStyle().onChange(of: side) { limit = 40 }.onChange(of: window) { limit = 40 }
    }
    private func row(_ session: BiometricSession, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                select(session)
            } label: {
                HStack {
                    Text(
                        session.start,
                        format: Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day())
                    Spacer()
                    Image(systemName: "arrow.up.right").accessibilityHidden(true)
                }.font(.subheadline.bold()).foregroundStyle(Theme.text1).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Focuses all charts on this session").accessibilityIdentifier(
                "biometrics.session.\(index)")
            Text(
                "\(clock(session.start)) → \(isOngoing(session) ? "now" : clock(session.end)) · \(session.records.count) readings"
            )
            .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if isOngoing(session), let live, live.stalled(side, now: .now) {
                Text("In bed · no vitals since \(clock(session.end))").font(.footnote).foregroundStyle(Theme.amber)
            } else {
                let buckets = movement.filter {
                    $0.date.map { $0 >= session.start.addingTimeInterval(-300) && $0 <= session.end } ?? false
                }
                Text(
                    "\(DisplayTime.duration(Int(session.end.timeIntervalSince(session.start)))) · \(buckets.isEmpty ? "No movement buckets" : "\(buckets.reduce(0) { $0 + $1.eventCount }) movement events")"
                )
                .font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), alignment: .leading),
                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 3), alignment: .leading, spacing: 14
            ) {
                ForEach(BiometricMetric.allCases) { metric in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(metric.title).font(.caption).foregroundStyle(Theme.text2)
                        if let stats = session.stats[metric] {
                            Text("\(metric.text(stats.average)) \(metric.unit)").font(
                                .mono(15, relativeTo: .subheadline)
                            ).foregroundStyle(Theme.text1)
                            Text("\(metric.text(stats.minimum))–\(metric.text(stats.maximum))").font(.caption2)
                                .foregroundStyle(Theme.text3)
                            BiometricRangeBar(metric: metric, stats: stats).frame(height: 8).accessibilityHidden(true)
                        } else {
                            Text("—").foregroundStyle(Theme.text2)
                        }
                        let watch = reference.readings(metric).filter {
                            session.interval.contains($0.date) && $0.value.isFinite
                        }
                        if let average = SleepPeriodSummary.average(watch.map(\.value)) {
                            Text(
                                "Watch\(metric == .hrv ? " SDNN" : "") \(metric.text(average)) · \(watch.count) samples"
                            ).font(.caption2).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(.vertical, 8)
    }
    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
    }
    private func isOngoing(_ session: BiometricSession) -> Bool {
        guard window.contains(.now), session.id == sessions.last?.id, let live, let latest = live.latest,
            live.sides[side.rawValue]?.available == true, live.sides[side.rawValue]?.occupied == true,
            live.credibility[side.rawValue] == "occupied", Date.now.timeIntervalSince(live.checked) < 30,
            latest >= session.start, latest <= session.end.addingTimeInterval(60)
        else { return false }
        return Date.now.timeIntervalSince(session.end) < 1800 || live.stalled(side, now: .now)
    }
}

private struct BiometricRangeBar: View {
    let metric: BiometricMetric
    let stats: BiometricPlot.Stats
    private var domain: ClosedRange<Double> {
        switch metric {
        case .heartRate: 36...90
        case .hrv: 0...110
        case .breathingRate: 10...26
        }
    }
    private var color: Color {
        switch metric {
        case .heartRate: Theme.red
        case .hrv: Theme.cool
        case .breathingRate: Theme.green
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let lower = position(stats.minimum) * geometry.size.width
            let upper = position(stats.maximum) * geometry.size.width
            Capsule().fill(Theme.track)
            Capsule().fill(color.opacity(0.5)).frame(width: max(2, upper - lower)).offset(x: lower)
            Circle().fill(color).frame(width: 8, height: 8).offset(
                x: min(geometry.size.width - 8, max(0, position(stats.average) * geometry.size.width - 4)))
        }
    }
    private func position(_ value: Double) -> Double {
        min(1, max(0, (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)))
    }
}
