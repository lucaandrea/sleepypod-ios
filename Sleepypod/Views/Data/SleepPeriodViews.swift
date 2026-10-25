import Charts
import SwiftUI

struct SleepWeekOverview: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let nights: [SleepNightSummary]
    let stages: [Int: SleepNightStageSummary]
    let selected: Date
    let calendar: Calendar
    let select: (Date) -> Void
    private var recorded: [SleepNightSummary] { nights.filter { !$0.records.isEmpty } }
    private var maximum: Double { max(8 * 3600, Double(nights.map(\.seconds).max() ?? 0) * 1.1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("SLEEP TIMELINE")
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(nights) { night in
                    let summary = night.main.flatMap { stages[$0.id] }
                    Button {
                        select(night.day)
                    } label: {
                        VStack(spacing: 2) {
                            if let summary, summary.asleepSeconds > 0 {
                                ForEach([SleepAnalyzer.SleepStage.rem, .light, .deep], id: \.self) { stage in
                                    Rectangle().fill(stage.displayColor).frame(
                                        height: max(0, height(night) * summary.fraction(stage)))
                                }
                            } else {
                                Rectangle().fill(night.records.isEmpty ? Theme.track : Theme.cool).frame(
                                    height: height(night))
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 6))
                            .opacity(calendar.isDate(night.day, inSameDayAs: selected) ? 1 : 0.65)
                            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 140, alignment: .bottom)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier(
                        "sleep.week.\(calendar.component(.day, from: night.day))"
                    )
                    .accessibilityLabel(
                        night.day.formatted(
                            Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
                    )
                    .accessibilityValue(
                        night.records.isEmpty
                            ? "No sleep recorded"
                            : "\(DisplayTime.duration(night.seconds)), \(summary?.quality.map { "quality \($0)" } ?? "quality unavailable")"
                    )
                    .accessibilityAddTraits(calendar.isDate(night.day, inSameDayAs: selected) ? .isSelected : [])
                }
            }
            HStack(spacing: 10) {
                ForEach(nights) { night in
                    Text(night.day, format: Date.FormatStyle(timeZone: calendar.timeZone).weekday(.narrow)).frame(
                        maxWidth: .infinity)
                }
            }.font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text2).accessibilityHidden(true)
            let layout =
                dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 16))
            layout {
                ForEach([SleepAnalyzer.SleepStage.rem, .light, .deep], id: \.self) { stage in
                    Label {
                        Text(stage.label)
                    } icon: {
                        Circle().fill(stage.displayColor).frame(width: 7, height: 7)
                    }
                }
            }.font(.caption).foregroundStyle(Theme.text2)
            Text(
                "Bar height is recorded sleep across all sessions. Colors show the main session’s classified stage proportions; plain bars have no stage result."
            )
            .font(.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            if recorded.isEmpty { Text("No sleep recorded this week").font(.footnote).foregroundStyle(Theme.text2) }
        }.cardStyle()
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("WEEK AVERAGES")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                value(
                    "Asleep",
                    text: SleepPeriodSummary.average(recorded.map { Double($0.seconds) }).map {
                        DisplayTime.duration(Int($0))
                    } ?? "—")
                value(
                    "Quality",
                    text: SleepPeriodSummary.average(
                        recorded.compactMap { $0.main.flatMap { stages[$0.id]?.quality }.map(Double.init) }
                    ).map { String(Int($0.rounded())) } ?? "—")
                value(
                    "Bedtime",
                    text: clock(
                        SleepPeriodSummary.averageClock(
                            recorded.compactMap { $0.main?.enteredBedDate }, calendar: calendar)))
                value(
                    "Wake",
                    text: clock(
                        SleepPeriodSummary.averageClock(
                            recorded.compactMap { $0.main?.completedAt }, calendar: calendar)))
            }
        }.cardStyle()
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("VITALS BY NIGHT")
            ForEach(BiometricMetric.allCases) { metric in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(metric.title) · \(metric.unit)").font(.subheadline)
                    let sources = Set(nights.compactMap { $0.metricSources[metric] })
                    let average =
                        sources.count <= 1
                        ? SleepPeriodSummary.average(nights.compactMap { $0.metrics[metric]?.average }) : nil
                    Text(
                        sources.count > 1
                            ? "Recorded methods changed; averages remain separate."
                            : "Average \(metric.text(average)) \(metric.unit)"
                    )
                    .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    Chart {
                        ForEach(Array(nights.enumerated()), id: \.element.id) { index, night in
                            if let average = night.metrics[metric]?.average {
                                PointMark(x: .value("Night", night.day), y: .value(metric.title, average))
                                    .foregroundStyle(color(metric))
                                LineMark(
                                    x: .value("Night", night.day), y: .value(metric.title, average),
                                    series: .value("Run", trendSegment(through: index, metric: metric))
                                )
                                .foregroundStyle(color(metric)).lineStyle(StrokeStyle(lineWidth: 1.5))
                            }
                        }
                    }.frame(height: dynamicTypeSize.isAccessibilitySize ? 210 : 90).chartLegend(.hidden).chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) }
                    }
                    .accessibilityLabel("\(metric.title) by night")
                }
            }
        }.cardStyle()
    }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .leading), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }
    private func height(_ night: SleepNightSummary) -> CGFloat {
        night.seconds > 0 ? max(6, 140 * Double(night.seconds) / maximum) : 4
    }
    private func clock(_ date: Date?) -> String {
        date?.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)) ?? "—"
    }
    private func value(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(Theme.text2)
            Text(text).font(.mono(23, weight: .light, relativeTo: .title2))
        }
        .frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func color(_ metric: BiometricMetric) -> Color {
        switch metric {
        case .heartRate: Theme.red
        case .hrv: Theme.cool
        case .breathingRate: Theme.green
        }
    }
    // A missing night or a changed processing method breaks the trend rather than joining unrelated observations.
    private func trendSegment(through index: Int, metric: BiometricMetric) -> Int {
        guard index > 0 else { return 0 }
        return (1...index).reduce(0) { count, position in
            count
                + (nights[position - 1].metrics[metric] == nil
                    || nights[position - 1].metricSources[metric] != nights[position].metricSources[metric] ? 1 : 0)
        }
    }
}

struct SleepMonthOverview: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let nights: [SleepNightSummary]
    let calendar: Calendar
    let loading: Bool
    let select: (Date) -> Void
    private var recorded: [SleepNightSummary] { nights.filter { !$0.records.isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("MONTH SUMMARY")
            let layout =
                dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                stat("Nights", loading ? "—" : String(recorded.count))
                stat(
                    "Avg sleep",
                    SleepPeriodSummary.average(recorded.map { Double($0.seconds) }).map {
                        DisplayTime.duration(Int($0))
                    } ?? "—")
                stat(
                    "Avg exits",
                    SleepPeriodSummary.average(recorded.map { Double($0.exits) }).map { String(format: "%.1f", $0) }
                        ?? "—")
            }
        }.cardStyle()
        if !dynamicTypeSize.isAccessibilitySize { calendarCard }
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("AVERAGE BY WEEK")
            ForEach(weeks, id: \.first?.day) { week in
                if let first = week.first, let last = week.last {
                    let average = SleepPeriodSummary.average(
                        week.filter { !$0.records.isEmpty }.map { Double($0.seconds) })
                    VStack(alignment: .leading, spacing: 6) {
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Text(weekLabel(first.day, last.day))
                                Spacer()
                                Text(average.map { DisplayTime.duration(Int($0)) } ?? "—")
                            }
                            VStack(alignment: .leading) {
                                Text(weekLabel(first.day, last.day))
                                Text(average.map { DisplayTime.duration(Int($0)) } ?? "—")
                            }
                        }.font(.footnote).foregroundStyle(Theme.text2)
                        ProgressView(value: min(1, (average ?? 0) / (9 * 3600))).tint(Theme.cool).accessibilityHidden(
                            true)
                    }
                }
            }
        }.cardStyle()
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("NIGHTS")
            if recorded.isEmpty {
                Text(loading ? "Loading nights…" : "No nights recorded this month").font(.footnote).foregroundStyle(
                    Theme.text2)
            }
            ForEach(recorded.reversed()) { night in
                Button {
                    select(night.day)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            night.day,
                            format: Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated).month(
                                .abbreviated
                            ).day()
                        ).foregroundStyle(Theme.text1)
                        Text(
                            "\(DisplayTime.duration(night.seconds)) · \(night.exits) \(night.exits == 1 ? "bed exit" : "bed exits")"
                        ).font(.footnote).foregroundStyle(Theme.text2)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }.buttonStyle(.plain).accessibilityHint("Opens this night").accessibilityIdentifier(
                    "sleep.monthNight.\(calendar.component(.day, from: night.day))")
                if night.id != recorded.first?.id { Divider().overlay(Theme.border1) }
            }
        }.cardStyle()
    }
    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hours asleep").font(.headline)
            Text("5h · lighter  /  8h · deeper blue").font(.caption).foregroundStyle(Theme.text2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(0..<7) { index in
                    Text(calendar.veryShortWeekdaySymbols[(index + calendar.firstWeekday - 1) % 7]).font(.caption2)
                        .foregroundStyle(Theme.text3)
                }
                ForEach(
                    Array(SleepPeriodSummary.monthCells(days: nights.map(\.day), calendar: calendar).enumerated()),
                    id: \.offset
                ) { _, day in
                    if let day, let night = nights.first(where: { $0.day == day }) {
                        Button {
                            select(day)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(calendar.component(.day, from: day))").foregroundStyle(Theme.text2)
                                Text(night.records.isEmpty ? "—" : String(format: "%.1f", Double(night.seconds) / 3600))
                                    .foregroundStyle(Theme.text1)
                            }.font(.mono(11, relativeTo: .caption2)).frame(
                                maxWidth: .infinity, minHeight: 50, alignment: .leading
                            ).padding(.horizontal, 5)
                                .background(
                                    night.records.isEmpty
                                        ? Theme.track.opacity(0.25)
                                        : Theme.cool.opacity(
                                            0.10 + 0.50 * min(1, max(0, (Double(night.seconds) / 3600 - 5) / 3))),
                                    in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(night.records.isEmpty)
                            .accessibilityLabel(
                                day.formatted(
                                    Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
                            )
                            .accessibilityValue(night.records.isEmpty ? "No data" : DisplayTime.duration(night.seconds))
                    } else {
                        Color.clear.frame(height: 50).accessibilityHidden(true)
                    }
                }
            }
        }.cardStyle().accessibilityIdentifier("sleep.monthCalendar")
    }
    private var weeks: [[SleepNightSummary]] {
        Dictionary(grouping: nights) { calendar.startOfWeek(for: $0.day) }.sorted { $0.key < $1.key }.map(\.value)
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.footnote).foregroundStyle(Theme.text2)
            Text(value).font(.mono(22, weight: .light, relativeTo: .title2))
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func weekLabel(_ first: Date, _ last: Date) -> String {
        first.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.abbreviated).day()) + " – "
            + last.formatted(Date.FormatStyle(timeZone: calendar.timeZone).day())
    }
}
