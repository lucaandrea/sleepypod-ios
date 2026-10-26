import SwiftUI

struct BiometricTraceScreen: View {
    @State private var model: BiometricTraceWorkspace
    @State private var metric = BiometricReportMetric.heartRate
    @Environment(SettingsManager.self) private var settings
    init(job: BiometricBacktestJob, side: Side, hash: String, kind: BiometricTraceWorkspace.Kind, nights: [BiometricNumericReport.Night], client: any BiometricReportsServing) {
        _model = State(initialValue: .init(job: job, side: side, hash: hash, kind: kind, nights: nights, client: client))
    }
    var body: some View {
        BiometricReportPage(title: model.kind == .stages ? "Replay stage traces" : "Recomputed traces") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Night").font(.headline)
                BiometricReportMenu(title: "Night", selection: Binding(get: { model.selection.cohortId }, set: { value in Task { await model.chooseNight(value) } }), options: model.nights.map(\.cohortId)) { $0 }
                    .disabled(model.loading || model.nights.isEmpty).accessibilityIdentifier("traces.night")
                Text("Configuration").font(.headline)
                BiometricReportMenu(title: "Configuration", selection: Binding(get: { model.selection.configuration }, set: { value in Task { await model.chooseConfiguration(value) } }), options: model.configurations) { $0.title(waveform: model.job.evaluationScope == .waveform) }
                    .disabled(model.loading || model.configurations.isEmpty).accessibilityIdentifier("traces.configuration")
                Text("Times shown in \(TimeZone(identifier: settings.timeZone)?.identifier ?? "GMT")").font(.footnote).foregroundStyle(Theme.text2)
            }.cardStyle()
            if let error = model.error { BiometricProfileError(error: error) }
            if model.configurations.isEmpty { Text("No evaluated configuration is available.").foregroundStyle(Theme.text2) }
            if model.loading { ProgressView("Loading trace page…") }
            Button("Refresh traces", systemImage: "arrow.clockwise") { Task { await model.load() } }.disabled(model.loading || model.configurations.isEmpty)
            if let page = model.stagePage { stageContent(page) }
            if let page = model.numericPage { numericContent(page) }
            ViewThatFits(in: .horizontal) {
                HStack { previous; Spacer(); next }
                VStack(alignment: .leading, spacing: 12) { previous; next }
            }
        }.task { await model.load() }
    }
    private var previous: some View { Button("Previous trace page", systemImage: "chevron.left") { Task { await model.back() } }.disabled(!model.canGoBack).opacity(model.canGoBack ? 1 : 0.4) }
    private var next: some View { Button("Next trace page", systemImage: "chevron.right") { Task { await model.forward() } }.disabled(model.loading || model.next == nil).opacity(model.next == nil ? 0.4 : 1) }
    private func stageContent(_ page: BiometricStageTracePage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Intervals \(page.items.isEmpty ? 0 : page.offset + 1)–\(page.offset + page.items.count) of \(page.totalItems)")
            Text("Only this page is plotted. Gaps are left empty; no stages are inferred between intervals. Reference scoring adds the frozen offset of \(page.clockOffsetMs) ms to these original timestamps.").font(.footnote).foregroundStyle(Theme.text2)
            if page.items.isEmpty { Text("No stage intervals were produced for this selection.").foregroundStyle(Theme.text2) }
            else { BiometricStageTraceChart(page: page).accessibilityIdentifier("traces.stageChart") }
            DisclosureGroup("Exact trace intervals") {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let first = page.items.first { BiometricProfileIdentity(title: "Configuration hash", value: first.configurationHash) }
                    ForEach(Array(page.items.enumerated()), id: \.offset) { _, row in
                        Divider(); Text(row.stage.title).font(.headline)
                        BiometricReportTimestamp(title: "Original start", milliseconds: row.startMs)
                        BiometricReportTimestamp(title: "Original end", milliseconds: row.endMs)
                    }
                }.padding(.top, 8)
            }.accessibilityIdentifier("traces.exactStages")
        }.cardStyle()
    }
    private func numericContent(_ page: BiometricNumericTracePage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Readings \(page.items.isEmpty ? 0 : page.offset + 1)–\(page.offset + page.items.count) of \(page.totalItems)")
            Text("Only this page is plotted. Dots are individual recomputed readings; gaps and missing values are not interpolated. Original stored readings remain unchanged.").font(.footnote).foregroundStyle(Theme.text2)
            Text("Reference scoring adds the frozen offset of \(page.clockOffsetMs) ms to these original timestamps.").font(.footnote).foregroundStyle(Theme.text2)
            BiometricReportMenu(title: "Metric", selection: $metric, options: BiometricReportMetric.allCases) { "\($0.title) · \($0.unit)" }
                .accessibilityIdentifier("traces.metric")
            if page.items.contains(where: { $0.value(metric) != nil }) { BiometricNumericTraceChart(items: page.items, metric: metric).accessibilityIdentifier("traces.numericChart") }
            else { Text("No values for this metric on the current page.").foregroundStyle(Theme.text2) }
            NavigationLink {
                BiometricReferenceOverlayScreen(job: model.job, side: model.side, selection: model.selection, items: page.items, metric: metric, clockOffset: page.clockOffsetMs, client: model.client)
                    .id("\(model.selection.contentHash):\(model.selection.cohortId):\(model.selection.configuration.rawValue):\(page.offset):\(metric.rawValue)")
            } label: { Label("Compare frozen references", systemImage: "square.on.circle") }.accessibilityIdentifier("traces.references")
            DisclosureGroup("Exact recomputed readings") {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let first = page.items.first { BiometricProfileIdentity(title: "Configuration hash", value: first.configHash) }
                    ForEach(Array(page.items.enumerated()), id: \.offset) { _, row in
                        Divider()
                        BiometricReportTimestamp(title: "Original time", milliseconds: row.timestampMs)
                        ReportValues(rows: [(metric.title, row.value(metric).map { ReportDisplay.number($0) + " " + metric.unit } ?? "Missing"), ("Quality", ReportDisplay.number(row.qualityScore)),
                                            ("Source channel", row.sourceSide.rawValue.capitalized), ("Flags", row.flags.map { $0.isEmpty ? "None" : $0.joined(separator: ", ") } ?? "Unknown"),
                                            ("Limitations", row.limitations.isEmpty ? "None" : row.limitations.joined(separator: ", "))])
                    }
                }.padding(.top, 8)
            }.accessibilityIdentifier("traces.exactNumeric")
        }.cardStyle()
    }
}

struct BiometricReferenceOverlayScreen: View {
    @State private var model: BiometricReferenceTraceWorkspace
    let items: [BiometricNumericTracePage.Item]
    let metric: BiometricReportMetric
    init(job: BiometricBacktestJob, side: Side, selection: BiometricTraceSelection, items: [BiometricNumericTracePage.Item], metric: BiometricReportMetric, clockOffset: Int, client: any BiometricReportsServing) {
        self.items = items; self.metric = metric
        let referenceMetric: BiometricReferenceTraceMetric = metric == .heartRate ? .heartRate : metric == .breathing ? .breathing : .variability
        _model = State(initialValue: .init(job: job, side: side, selection: selection, metric: referenceMetric, clockOffset: clockOffset, client: client))
    }
    var body: some View {
        BiometricReportPage(title: "Frozen references") {
            Text(metric.title + " · " + metric.unit).font(.headline)
            Text("Circles are recomputed readings, squares are reference points, and bars are reference intervals. Only the two displayed pages are shown. This overlay does not create matched pairs or new scores.").font(.footnote).foregroundStyle(Theme.text2)
            if let error = model.error { BiometricProfileError(error: error) }
            if model.loading { ProgressView("Loading frozen references…") }
            Button("Refresh references", systemImage: "arrow.clockwise") { Task { await model.load() } }.disabled(model.loading)
            if let page = model.page {
                Text("The frozen offset of \(page.clockOffsetMs) ms is added to recomputed timestamps here. Reference times stay unchanged. Point matching tolerance: \(page.pointToleranceMs) ms.").font(.footnote).foregroundStyle(Theme.text2)
                if items.contains(where: { $0.value(metric) != nil }) || page.items.contains(where: { $0.compatibility == nil && $0.value != nil }) {
                    BiometricReferenceOverlayChart(items: items, metric: metric, references: page).accessibilityIdentifier("traces.referenceChart")
                } else { Text("No compatible values on these pages.").foregroundStyle(Theme.text2) }
                Text("Reference records \(page.items.isEmpty ? 0 : page.offset + 1)–\(page.offset + page.items.count) of \(page.totalItems)")
                DisclosureGroup("Frozen source records") {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Text("Source times below are UTC. Incompatible records are listed but not plotted.").font(.footnote).foregroundStyle(Theme.text2)
                        ForEach(Array(page.items.enumerated()), id: \.offset) { _, row in
                            Divider(); Text("\(row.source) · Revision \(row.importRevision)").font(.headline)
                            ReportValues(rows: [("Start · UTC", ReferenceLabels.utc(row.startMs)), ("End · UTC", row.temporalKind == "point" ? "Point" : ReferenceLabels.utc(row.endMs)),
                                                ("Value", row.value.map { ReportDisplay.number($0) + " " + row.unit } ?? "Missing"), ("Aggregation", ReportDisplay.label(row.aggregation)),
                                                ("Compatibility", row.compatibility.map(ReportDisplay.label) ?? "Compatible")])
                        }
                    }.padding(.top, 8)
                }.cardStyle().accessibilityIdentifier("traces.exactReferences")
            }
            ViewThatFits(in: .horizontal) {
                HStack { previous; Spacer(); next }
                VStack(alignment: .leading, spacing: 12) { previous; next }
            }
        }.task { await model.load() }
    }
    private var previous: some View { Button("Previous reference page", systemImage: "chevron.left") { Task { await model.back() } }.disabled(!model.canGoBack).opacity(model.canGoBack ? 1 : 0.4) }
    private var next: some View { Button("Next reference page", systemImage: "chevron.right") { Task { await model.forward() } }.disabled(model.loading || model.page?.nextCursor == nil).opacity(model.page?.nextCursor == nil ? 0.4 : 1) }
}
