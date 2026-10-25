import Charts
import SwiftUI

struct BiometricsScreen: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model = BiometricsWorkspace(
        api: APIBackend.current.createClient(),
        referenceAPI: APIBackend.current == .freeSleep
            ? nil
            : APIBackend.current.isDemo
                ? DemoWatchReferenceClient() as any WatchReferenceClient : CoreWatchReferenceClient(),
        contextAPI: APIBackend.current == .freeSleep
            ? nil
            : APIBackend.current.isDemo
                ? DemoBiometricsContextClient() as any BiometricsContextClient : CoreBiometricsContextClient())
    @State private var side: Side
    @State private var through: Date
    @State private var period: BiometricRange = .week
    @State private var viewport: BiometricViewport
    @State private var selected: Date?
    @State private var selectedRange: ClosedRange<Date>?
    @State private var selectRange = false
    @State private var showRaw = false
    @State private var showLog = false
    @State private var showImport = false
    @State private var showReference = true
    @AppStorage("collapseBiometricGaps") private var collapseGaps = true
    init(side: Side, date: Date, period: BiometricRange = .week) {
        _side = State(initialValue: side)
        _through = State(initialValue: date)
        _period = State(initialValue: period)
        _viewport = State(initialValue: BiometricViewport(start: date, end: date.addingTimeInterval(86400)))
    }
    private var calendar: Calendar { SleepCalendar.calendar(timeZone: settings.timeZone) }
    private var window: DateInterval { period.window(through: through, calendar: calendar) }
    private var queryKey: String {
        "\(side.rawValue)-\(window.start.timeIntervalSince1970)-\(window.end.timeIntervalSince1970)"
    }
    private var intervals: [ClosedRange<Date>] {
        if !model.sessions.isEmpty { return model.sessions.map(\.interval) }
        return model.movementIntervals + (showReference ? model.referenceIntervals : [])
    }
    private var fullAxis: BiometricTimeAxis {
        BiometricTimeAxis(intervals: intervals, window: viewport.full, collapse: collapseGaps)
    }
    private var chartAxis: BiometricTimeAxis {
        BiometricTimeAxis(intervals: intervals, window: viewport.window, collapse: collapseGaps)
    }
    private var zoom: Double { viewport.zoom(using: fullAxis) }
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    controls
                    if APIBackend.current != .freeSleep { referenceControls }
                    if model.loading { ProgressView("Loading biometrics…") }
                    if let error = model.error {
                        Text(error).font(.footnote).foregroundStyle(Theme.amber)
                        Button("Retry") { Task { await load() } }
                    }
                    if !model.loading && !model.loadingReference && model.error == nil && model.vitals.isEmpty
                        && model.reference.count == 0 {
                        ContentUnavailableView(
                            "No readings", systemImage: "waveform.path.ecg",
                            description: Text("Choose another date or side."))
                    }
                    if !model.vitals.isEmpty || model.reference.count > 0 {
                        chartNavigation.id("biometrics-charts")
                        ForEach(BiometricMetric.allCases) { metric in
                            let plot = model.plots[metric] ?? BiometricPlot(metric: metric, records: [])
                            BiometricChartCard(
                                plot: plot, viewport: viewport.window, axis: chartAxis, selected: $selected,
                                range: $selectedRange, selectRange: selectRange,
                                reference: showReference ? model.reference.readings(metric) : [],
                                referencePlot: showReference ? model.referencePlots[metric] : nil
                            )
                            .simultaneousGesture(
                                MagnifyGesture().onEnded { value in
                                    viewport.scale(value.magnification, anchor: selected, using: fullAxis)
                                })
                        }
                        movementChart
                        Text(
                            "Faint lines show original readings; solid lines show a 9-minute average. Shading and summary values describe the full period, including when zoomed in. Gaps and changes in the recorded processing method stay separate."
                        )
                        .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        Text(
                            "The current Pod HRV is a window IBI variability index. Older readings may have an unknown definition. Apple Watch uses SDNN; these values are not interchangeable."
                        )
                        .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        BiometricSessionsCard(
                            sessions: model.sessions, movement: model.movementBuckets,
                            reference: showReference ? model.reference : WatchReferenceData(), live: model.liveStatus,
                            side: side, window: window
                        ) {
                            viewport.focus($0.interval)
                            selected = nil
                            selectedRange = nil
                            withAnimation { scroll.scrollTo("biometrics-charts", anchor: .top) }
                        }
                        Button("Raw log", systemImage: "list.bullet.rectangle") { showLog = true }
                        Button("Raw data", systemImage: "square.and.arrow.up") { showRaw = true }
                    }
                    if APIBackend.current != .freeSleep { presence }
                }.frame(maxWidth: 880).padding(16).frame(maxWidth: .infinity)
            }
        }.background(Theme.background).navigationTitle("Biometrics").navigationBarTitleDisplayMode(.inline)
            .environment(\.timeZone, calendar.timeZone)
            .task(id: "\(queryKey)-\(scenePhase)") {
                guard scenePhase == .active else { return }
                await load()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await load(resetViewport: false)
                }
            }
            .task(id: "\(side.rawValue)-\(scenePhase)") {
                guard scenePhase == .active, APIBackend.current != .freeSleep else { return }
                while !Task.isCancelled {
                    await model.loadLive(side: side)
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
            .refreshable { await load() }
            .onChange(of: collapseGaps) {
                viewport.reset()
                selected = nil
                selectedRange = nil
            }
            .sheet(isPresented: $showRaw) {
                RawDataSheet(
                    side: side, start: window.start, end: window.end, vitals: model.vitals, sleep: model.sleep,
                    movement: model.movement, reference: model.reference)
            }
            .sheet(isPresented: $showLog) { RawVitalsLog(records: model.vitals) }
            .sheet(isPresented: $showImport) {
                WatchImportSheet(side: side) { await model.loadReference(side: side, window: window) }
            }
    }
    private var presence: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live presence").font(.headline)
            if let status = model.liveStatus {
                if status.stalled(side, now: .now) {
                    Label(
                        "This side is occupied, but vitals have stopped arriving.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                    Text(
                        status.latest.map {
                            "Last reading: "
                                + $0.formatted(
                                    Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone))
                        } ?? "No vital reading has arrived yet."
                    ).foregroundStyle(Theme.text2)
                }
                ForEach(Side.allCases) { currentSide in
                    if let presence = status.sides[currentSide.rawValue] {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(settings.sideName(for: currentSide)).font(.subheadline.bold())
                            Text(
                                !presence.available
                                    ? "Presence unavailable"
                                    : status.credibility[currentSide.rawValue] == "suspect"
                                        ? "Presence uncertain" : presence.occupied ? "In bed" : "Empty"
                            )
                            .foregroundStyle(presence.available && presence.occupied ? Theme.green : Theme.text2)
                            Text(
                                "Movement: \(presence.movement.active ? "active" : "idle") · peak \(Int(presence.movement.peakScore)) · level \(presence.level.deviation.map { String(format: "%.1f", $0) } ?? "—")"
                            )
                            .font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(
                    "Updated \(status.checked.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)))"
                ).foregroundStyle(Theme.text3)
            } else if let error = model.liveError {
                Text(error).foregroundStyle(Theme.amber)
            } else {
                ProgressView("Checking presence…")
            }
        }.font(.footnote).cardStyle()
    }
    private var referenceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Imported Apple Watch", isOn: $showReference).tint(Theme.green)
            if model.loadingReference {
                ProgressView("Loading reference data…")
            } else if let error = model.referenceError {
                Text(error).foregroundStyle(Theme.amber)
                Button("Retry reference data") { Task { await model.loadReference(side: side, window: window) } }
            } else {
                Text(
                    "\(model.reference.count) imported reference readings and stages. Watch lines are dashed; SDNN HRV uses separate points."
                ).foregroundStyle(Theme.text2)
                if !model.reference.extendedMetrics {
                    Text("This controller does not expose imported breathing or SDNN HRV samples.").foregroundStyle(
                        Theme.text2)
                }
            }
            Button("Import Apple Watch data", systemImage: "arrow.up.doc") { showImport = true }
                .accessibilityIdentifier("sleep.importWatch")
        }.font(.footnote).cardStyle()
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Side", selection: $side) { ForEach(Side.allCases) { Text(settings.sideName(for: $0)).tag($0) } }
                .pickerStyle(.segmented)
            Picker("Range", selection: $period) { ForEach(BiometricRange.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            DatePicker("Through date", selection: $through, in: ...Date.now, displayedComponents: .date)
            HStack(spacing: 20) {
                Button("Earlier", systemImage: "chevron.left") { shift(-1) }
                Button("Latest") { through = .now }
                Button("Later", systemImage: "chevron.right") { shift(1) }.disabled(calendar.isDateInToday(through))
            }.buttonStyle(.bordered)
        }
    }
    private var chartNavigation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "\(viewport.window.lowerBound.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone))) → \(viewport.window.upperBound.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: calendar.timeZone)))"
            )
            .font(.footnote).foregroundStyle(Theme.text2)
            ViewThatFits(in: .horizontal) {
                zoomButtons(vertical: false)
                zoomButtons(vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                panButtons(vertical: false)
                panButtons(vertical: true)
            }
            Toggle("Collapse gaps between sessions", isOn: $collapseGaps).tint(Theme.green).accessibilityIdentifier(
                "biometrics.collapseGaps")
            if collapseGaps {
                Text("Dashed dividers mark collapsed gaps. Each session keeps its real clock times.").font(.caption)
                    .foregroundStyle(Theme.text2)
            }
            Toggle("Select a range", isOn: $selectRange).tint(Theme.green)
            if selected != nil { Button("Clear reading") { selected = nil } }
            if selectRange {
                Button("Focus selected range") {
                    if let selectedRange {
                        viewport.focus(selectedRange)
                        selected = nil
                        self.selectedRange = nil
                        selectRange = false
                    }
                }.disabled(selectedRange == nil)
            }
            Text(
                "\(Int(zoom.rounded()))× · \(selectRange ? "Drag across a chart to focus on a range." : "Touch and hold to inspect a reading. Pinch to zoom.")"
            )
            .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("biometrics.zoomStatus")
        }.cardStyle()
    }
    private func zoomButtons(vertical: Bool) -> some View {
        let layout =
            vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button("Zoom out", systemImage: "minus.magnifyingglass") {
                viewport.scale(0.5, anchor: selected, using: fullAxis)
            }.disabled(zoom <= 1.01)
            Button("Zoom in", systemImage: "plus.magnifyingglass") {
                viewport.scale(2, anchor: selected, using: fullAxis)
            }.disabled(zoom >= 15.99)
            Button("Reset", systemImage: "arrow.counterclockwise") {
                viewport.reset()
                selected = nil
                selectedRange = nil
            }
        }.buttonStyle(.bordered).font(.subheadline)
    }
    private func panButtons(vertical: Bool) -> some View {
        let layout =
            vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button("Pan earlier", systemImage: "arrow.left") { viewport.pan(-1, using: fullAxis) }.disabled(
                fullAxis.position(viewport.window.lowerBound) <= 0)
            Button("Pan later", systemImage: "arrow.right") { viewport.pan(1, using: fullAxis) }.disabled(
                fullAxis.position(viewport.window.upperBound) >= 1)
        }.buttonStyle(.bordered).font(.subheadline)
    }
    @ViewBuilder private var movementChart: some View {
        if APIBackend.current != .freeSleep { bucketChart } else { rawMovementChart }
    }
    private var bucketChart: some View {
        let axis = chartAxis
        return VStack(alignment: .leading, spacing: 12) {
            Text("Position changes").font(.headline)
            Text("Events per hour · 5-minute buckets within recorded in-bed periods").font(.footnote).foregroundStyle(
                Theme.text2)
            if let error = model.contextError { Text(error).foregroundStyle(Theme.amber).font(.footnote) }
            let visible = model.movementBuckets.filter { $0.date.map { viewport.window.contains($0) && axis.segmentIndex(containing: $0) != nil } ?? false }
            if visible.isEmpty {
                Text("No qualifying movement events in this interval.").font(.footnote).foregroundStyle(Theme.text2)
            } else {
                Chart(visible) { bucket in
                    if let date = bucket.date {
                        BarMark(
                            xStart: .value("Start", axis.position(date)),
                            xEnd: .value("End", axis.position(date.addingTimeInterval(300))),
                            y: .value("Events/hour", bucket.eventsPerHour)
                        ).foregroundStyle(Theme.amber)
                    }
                }.chartXScale(domain: 0.0...1.0).chartXSelection(value: selectedPosition).chartXAxis {
                    BiometricTimeAxisMarks.content(axis: axis, window: viewport.window, timeZone: calendar.timeZone, largeText: dynamicTypeSize.isAccessibilitySize)
                }.frame(height: dynamicTypeSize.isAccessibilitySize ? 220 : 140).chartPlotStyle { $0.clipped() }
                if let selected,
                    let bucket = visible.first(where: {
                        $0.date.map { selected >= $0 && selected < $0.addingTimeInterval(300) } ?? false
                    }) {
                    Text("\(bucket.eventCount) events in 5 minutes · \(bucket.sampleCount) samples").font(.footnote)
                }
            }
            Text("The controller excludes empty-bed noise. Raw movement scores remain available in CSV exports.").font(
                .caption
            ).foregroundStyle(Theme.text3)
        }.cardStyle()
    }
    private var rawMovementChart: some View {
        let axis = chartAxis
        return VStack(alignment: .leading, spacing: 12) {
            Text("Movement").font(.headline)
            Text("Recorded movement score").font(.footnote).foregroundStyle(Theme.text2)
            let visible = model.movement.filter { viewport.window.contains($0.date) && axis.segmentIndex(containing: $0.date) != nil }
            if visible.isEmpty {
                Text("No movement readings in this interval.").font(.footnote)
            } else {
                Chart(visible) { reading in
                    BarMark(
                        x: .value("Time", axis.position(reading.date)),
                        y: .value("Movement score", reading.totalMovement)
                    ).foregroundStyle(Theme.amber)
                }.chartXScale(domain: 0.0...1.0).chartXSelection(value: selectedPosition).chartXAxis {
                    BiometricTimeAxisMarks.content(axis: axis, window: viewport.window, timeZone: calendar.timeZone, largeText: dynamicTypeSize.isAccessibilitySize)
                }.frame(height: dynamicTypeSize.isAccessibilitySize ? 220 : 140)
                if let selected,
                    let nearest = visible.min(by: {
                        abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected))
                    }), abs(nearest.date.timeIntervalSince(selected)) <= 5 * 60 {
                    Text(
                        "\(nearest.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))) · score \(nearest.totalMovement)"
                    ).font(.footnote)
                }
            }
        }.cardStyle()
    }
    private var selectedPosition: Binding<Double?> {
        Binding(get: { selected.map(chartAxis.position) }, set: { position in
            if let position { selected = chartAxis.date(at: position) }
        })
    }
    private func shift(_ direction: Int) {
        let days = period == .night ? 1 : period == .week ? 7 : 30
        through = min(.now, calendar.date(byAdding: .day, value: direction * days, to: through) ?? through)
    }
    private func load(resetViewport: Bool = true) async {
        if resetViewport {
            viewport = BiometricViewport(start: window.start, end: window.end)
            selected = nil
            selectedRange = nil
        }
        await model.load(side: side, window: window)
        guard !Task.isCancelled else { return }
        async let reference: Void = model.loadReference(side: side, window: window)
        async let movement: Void = model.loadMovement(side: side, window: window)
        _ = await (reference, movement)
    }
}

struct BiometricChartCard: View {
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let plot: BiometricPlot
    let viewport: ClosedRange<Date>
    let axis: BiometricTimeAxis
    @Binding var selected: Date?
    @Binding var range: ClosedRange<Date>?
    let selectRange: Bool
    var reference: [WatchComparison.Reading] = []
    var referencePlot: BiometricPlot?
    private var color: Color {
        switch plot.metric {
        case .heartRate: Theme.red
        case .hrv: Theme.cool
        case .breathingRate: Theme.green
        }
    }
    private var visible: [BiometricPlot.Point] { plot.displayPoints(in: viewport) }
    private var referencePoints: [BiometricPlot.Point] {
        (referencePlot?.displayPoints(in: viewport, budget: 800) ?? []).filter { axis.segmentIndex(containing: $0.date) != nil }
    }
    private var nearest: BiometricPlot.Point? {
        guard let selected, viewport.contains(selected),
            let point = plot.points.min(by: {
                abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected))
            }), viewport.contains(point.date), abs(point.date.timeIntervalSince(selected)) <= 5 * 60
        else { return nil }
        return point
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plot.metric.title).font(.headline)
            if let nearest {
                Text(
                    "\(nearest.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))) · \(plot.metric.text(nearest.value)) \(plot.metric.unit)"
                ).font(.footnote).foregroundStyle(color).accessibilityIdentifier(
                    "biometrics.reading.\(plot.metric.rawValue)")
            } else if let selected, viewport.contains(selected) {
                Text("No reading near the selected time").font(.footnote).foregroundStyle(Theme.text2)
            }
            if visible.isEmpty && referencePoints.isEmpty {
                Text("No readings in this interval").font(.footnote).foregroundStyle(Theme.text2).frame(minHeight: 150)
            } else {
                Group {
                    if selectRange {
                        chart.chartXSelection(range: selectedPositions).chartGesture { proxy in
                            DragGesture(minimumDistance: 0).onChanged { value in
                                proxy.selectXRange(from: value.startLocation.x, to: value.location.x)
                            }
                        }
                    } else {
                        chart.chartXSelection(value: selectedPosition)
                    }
                }.frame(height: dynamicTypeSize.isAccessibilitySize ? 260 : 190).accessibilityLabel("\(plot.metric.title) chart").accessibilityIdentifier(
                    "biometrics.chart.\(plot.metric.rawValue)")
            }
            if let stats = plot.stats {
                Text(
                    "Full period · Min \(plot.metric.text(stats.minimum)) · Avg \(plot.metric.text(stats.average)) · Max \(plot.metric.text(stats.maximum)) \(plot.metric.unit)"
                )
                .font(.footnote).monospacedDigit().foregroundStyle(Theme.text2).fixedSize(
                    horizontal: false, vertical: true)
            }
            if plot.points.filter({ viewport.contains($0.date) }).count > visible.count {
                Text("Display simplified for this range. Raw log and exports retain every reading.").font(.caption)
                    .foregroundStyle(Theme.text3)
            }
            if plot.mixedSources {
                Text("A combined average is unavailable because recorded processing methods differ.").font(.footnote)
                    .foregroundStyle(Theme.text2)
            }
            if !reference.isEmpty {
                Text(
                    plot.metric == .hrv
                        ? "Apple Watch SDNN · hollow points. Pod IBI variability and Watch SDNN are different measurements."
                        : "Apple Watch · dashed line. Imported reference data stays separate from Pod averages."
                )
                .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if let selected, viewport.contains(selected),
                    let nearest = reference.min(by: {
                        abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected))
                    }), viewport.contains(nearest.date), abs(nearest.date.timeIntervalSince(selected)) <= 5 * 60 {
                    Text("Watch: \(plot.metric.text(nearest.value)) \(plot.metric.unit)").font(.footnote)
                }
            }
        }.cardStyle()
    }
    private var verticalDomain: ClosedRange<Double> {
        let values =
            visible.map(\.value) + referencePoints.map(\.value)
            + [plot.stats?.lower, plot.stats?.upper].compactMap { $0 }
        let lower = values.min() ?? 0
        let upper = values.max() ?? 1
        let padding = max(1, (upper - lower) * 0.12)
        return max(0, lower - padding)...(upper + padding)
    }
    private var selectedPosition: Binding<Double?> {
        Binding(get: { selected.map(axis.position) }, set: { position in
            if let position { selected = axis.date(at: position) }
        })
    }
    private var selectedPositions: Binding<ClosedRange<Double>?> {
        Binding(
            get: { range.map { axis.position($0.lowerBound)...axis.position($0.upperBound) } },
            set: { positions in
                guard let positions, let start = axis.date(at: positions.lowerBound),
                    let end = axis.date(at: positions.upperBound), end >= start
                else {
                    range = nil
                    return
                }
                range = start...end
            })
    }
    private var chart: some View {
        Chart {
            if let stats = plot.stats {
                RectangleMark(
                    xStart: .value("Start", 0.0), xEnd: .value("End", 1.0),
                    yStart: .value("Lower quartile", stats.lower), yEnd: .value("Upper quartile", stats.upper)
                )
                .foregroundStyle(color.opacity(0.08))
            }
            ForEach(visible) { point in
                LineMark(
                    x: .value("Time", axis.position(point.date)), y: .value("Reading", point.value),
                    series: .value("Run", "raw-\(point.segment)")
                )
                .foregroundStyle(color.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
                LineMark(
                    x: .value("Time", axis.position(point.date)), y: .value("Average", point.smooth),
                    series: .value("Run", "smooth-\(point.segment)")
                )
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(referencePoints) { point in
                if plot.metric == .hrv {
                    PointMark(x: .value("Time", axis.position(point.date)), y: .value("Watch SDNN", point.value))
                        .symbol { Circle().strokeBorder(Theme.text2, lineWidth: 1.4).frame(width: 5, height: 5) }
                } else {
                    LineMark(
                        x: .value("Time", axis.position(point.date)), y: .value("Watch", point.value),
                        series: .value("Run", "watch-\(point.segment)-\(axis.segmentIndex(containing: point.date) ?? 0)")
                    )
                    .foregroundStyle(Theme.text2).lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                }
            }
            if selectRange, let range {
                RectangleMark(
                    xStart: .value("Selection start", axis.position(range.lowerBound)),
                    xEnd: .value("Selection end", axis.position(range.upperBound))
                ).foregroundStyle(Theme.cool.opacity(0.12))
            }
            ForEach(axis.breaks, id: \.self) { position in
                RuleMark(x: .value("Gap", position)).foregroundStyle(Theme.text3.opacity(0.5)).lineStyle(
                    StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
            if let selected, viewport.contains(selected) {
                RuleMark(x: .value("Selected", axis.position(selected))).foregroundStyle(Theme.text2.opacity(0.5))
            }
            if let nearest {
                PointMark(x: .value("Time", axis.position(nearest.date)), y: .value("Reading", nearest.value))
                    .foregroundStyle(Theme.text1)
            }
        }.chartXScale(domain: 0.0...1.0).chartYScale(domain: verticalDomain).chartLegend(.hidden)
            .chartXAxis { BiometricTimeAxisMarks.content(axis: axis, window: viewport, timeZone: timeZone, largeText: dynamicTypeSize.isAccessibilitySize) }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            .chartPlotStyle { $0.clipped() }
    }
}

enum BiometricTimeAxisMarks {
    @AxisContentBuilder static func content(axis: BiometricTimeAxis, window: ClosedRange<Date>, timeZone: TimeZone, largeText: Bool)
        -> some AxisContent {
        AxisMarks(values: largeText ? [0.0, 1.0] : [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
            AxisValueLabel {
                if let position = value.as(Double.self), let date = axis.date(at: position) {
                    Text(date, format: window.upperBound.timeIntervalSince(window.lowerBound) > 86400
                         ? Date.FormatStyle(timeZone: timeZone).month(.abbreviated).day()
                         : Date.FormatStyle(timeZone: timeZone).hour().minute())
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            AxisTick()
        }
    }
}

struct RawVitalsLog: View {
    enum SortColumn: String, CaseIterable, Identifiable {
        case time = "Time"
        case heartRate = "Heart rate"
        case hrv = "HRV"
        case breathing = "Breathing"
        var id: String { rawValue }
    }
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dismiss) private var dismiss
    let records: [VitalsRecord]
    @State private var search = ""
    @State private var limit = 100
    @State private var sort: SortColumn = .time
    @State private var descending = true
    private var filtered: [VitalsRecord] {
        let matched = records.filter {
            search.isEmpty
                || "\($0.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))) \(SleepCSV.number($0.heartRate)) \(SleepCSV.number($0.hrv)) \(SleepCSV.number($0.breathingRate)) \($0.sourceKey)"
                    .localizedCaseInsensitiveContains(search)
        }
        let selectedSort = sort
        return matched.sorted { first, second in
            func value(_ record: VitalsRecord) -> Double? {
                switch selectedSort {
                case .time: record.date.timeIntervalSince1970
                case .heartRate: BiometricMetric.heartRate.value(record)
                case .hrv: BiometricMetric.hrv.value(record)
                case .breathing: BiometricMetric.breathingRate.value(record)
                }
            }
            guard let firstValue = value(first) else { return value(second) == nil && first.id < second.id }
            guard let secondValue = value(second) else { return true }
            if firstValue == secondValue { return first.id < second.id }
            return descending ? firstValue > secondValue : firstValue < secondValue
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Picker("Sort by", selection: $sort) { ForEach(SortColumn.allCases) { Text($0.rawValue).tag($0) } }
                Toggle(sort == .time ? "Newest first" : "Highest first", isOn: $descending)
                Text("\(filtered.count) original readings").font(.footnote).foregroundStyle(Theme.text2)
                ForEach(Array(filtered.prefix(limit))) { record in
                    DisclosureGroup {
                        Text("Run: \(record.sourceKey)")
                        Text("Status: \(record.provenance?.status ?? "legacy_unknown")")
                        Text("HRV definition: \(record.hrvMetricID ?? "Unknown")")
                        if let hash = record.provenance?.configurationHash {
                            Text("Configuration: \(hash)").textSelection(.enabled)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(
                                record.date.formatted(
                                    Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone)))
                            Text(
                                "HR \(BiometricMetric.heartRate.text(record.heartRate)) · HRV \(BiometricMetric.hrv.text(record.hrv)) · BR \(BiometricMetric.breathingRate.text(record.breathingRate))"
                            )
                            .font(.footnote).monospacedDigit().foregroundStyle(Theme.text2)
                        }.padding(.vertical, 4)
                    }.font(.footnote)
                }
                if filtered.count > limit { Button("Show 100 more") { limit += 100 } }
            }.searchable(text: $search, prompt: "Find a time, value, or processing run")
                .navigationTitle("Raw log").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onChange(of: search) { limit = 100 }
                .onChange(of: sort) { limit = 100 }
                .onChange(of: descending) { limit = 100 }
        }
    }
}
