import SwiftUI

struct BiometricReportScreen: View {
    let model: BiometricDatasetWorkspace
    let job: BiometricBacktestJob
    @State private var reading: BiometricReportWorkspace
    @State private var confirmRelease = false
    init(model: BiometricDatasetWorkspace, job: BiometricBacktestJob) {
        self.model = model; self.job = job
        _reading = State(initialValue: .init(job: job, side: model.side, client: model.client.reportClient))
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: model.side)
                if APIBackend.current.isDemo { Text("Demo · precomputed Core examples from synthetic readings. These are separate from requests you queue. No personal sleep records or live processing are represented.").font(.footnote).foregroundStyle(Theme.text2) }
                if let error = reading.error { BiometricProfileError(error: error) }
                Button("Refresh report", systemImage: "arrow.clockwise") { Task { await reading.load() } }.disabled(reading.loading)
                if reading.loading && !reading.loaded { ProgressView("Loading report…") }
                if let descriptor = reading.descriptor {
                    if let report = reading.report {
                        BiometricReportOverview(report: report, descriptor: descriptor)
                        if let numeric = reading.numeric {
                            NavigationLink { BiometricNumericReportScreen(report: numeric, waveform: report.hasWaveforms) } label: {
                                SettingsRow("Numerical comparisons", icon: "waveform.path.ecg", tile: true, chevron: true)
                            }.cardStyle().accessibilityIdentifier("reports.numeric")
                        }
                        if let numeric = reading.numeric {
                            if report.hasWaveforms {
                                NavigationLink { BiometricTraceScreen(job: job, side: model.side, hash: descriptor.contentHash, kind: .numeric, nights: numeric.nights, client: model.client.reportClient) } label: { Label("Inspect recomputed traces", systemImage: "waveform.path") }.accessibilityIdentifier("reports.numericTraces")
                            }
                            if report.hasStages {
                                NavigationLink { BiometricTraceScreen(job: job, side: model.side, hash: descriptor.contentHash, kind: .stages, nights: numeric.nights, client: model.client.reportClient) } label: { Label("Inspect stage traces", systemImage: "chart.bar.xaxis") }.accessibilityIdentifier("reports.stageTraces")
                            }
                        }
                        if let error = reading.numericError { BiometricProfileError(error: error) }
                        if let stages = reading.stages {
                            NavigationLink { BiometricStageReportScreen(report: stages, summaries: report.stageNightSummary, waveform: report.hasWaveforms) } label: {
                                SettingsRow("Stage coverage and confusion", icon: "chart.bar.xaxis", tile: true, chevron: true)
                            }.cardStyle().accessibilityIdentifier("reports.stages")
                        }
                        if let error = reading.stageError { BiometricProfileError(error: error) }
                        if report.hasWaveforms { BiometricReplayResourcesView(report: report) }
                        BiometricReportPolicyView(report: report)
                        BiometricReportIdentityView(report: report, descriptor: descriptor)
                        Button("Release detailed report", role: .destructive) { confirmRelease = true }
                            .disabled(!model.canMutate || reading.loading || reading.error != nil || job.state != .succeeded).accessibilityIdentifier("reports.release")
                    } else if !descriptor.available {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Detailed results released").font(.headline).accessibilityIdentifier("reports.released")
                            Text("The audit hash remains. Detailed scores and traces are unavailable.").foregroundStyle(Theme.text2)
                            BiometricProfileIdentity(title: "Report hash", value: descriptor.contentHash)
                        }.cardStyle()
                    }
                } else if reading.loaded && reading.error == nil {
                    Text("No committed report is available yet.").foregroundStyle(Theme.text2).accessibilityIdentifier("reports.empty")
                }
                BiometricBacktestPendingCard(model: model)
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Evaluation report").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("reports.content")
            .task { await reading.load() }
            .onChange(of: model.reportReceipt) { _, receipt in if let receipt { reading.acceptRelease(receipt) } }
            .confirmationDialog("Permanently release detailed results? The report hash, job history and holdout exposure audit remain.", isPresented: $confirmRelease, titleVisibility: .visible) {
                Button("Permanently release report", role: .destructive) { if let descriptor = reading.descriptor { Task { await model.releaseReport(job: job, descriptor: descriptor) } } }.accessibilityIdentifier("reports.confirmRelease")
                Button("Keep report", role: .cancel) {}
            }
    }
}

struct BiometricReportExamplesScreen: View {
    let model: BiometricDatasetWorkspace
    @State private var examples: [BiometricReportExample] = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Synthetic examples").font(.headline)
                Text("These left-side examples were scored by Core from generated data. They do not evaluate your saved candidates or approve a profile change.").font(.footnote).foregroundStyle(Theme.text2)
                if let error { BiometricProfileError(error: error) }
                ForEach(examples) { example in
                    NavigationLink { BiometricReportScreen(model: model, job: example.job) } label: {
                        SettingsRow(example.title, icon: "chart.xyaxis.line", tile: true, chevron: true)
                    }.cardStyle().accessibilityIdentifier("reports.example.\(example.name)")
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Example reports").navigationBarTitleDisplayMode(.inline)
            .task { do { examples = try BiometricReportExample.load() } catch { self.error = error.localizedDescription } }
    }
}

struct BiometricReportOverview: View {
    let report: BiometricEvaluationReport
    let descriptor: BiometricReportDescriptor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.status.title).font(.title2).accessibilityIdentifier("reports.status")
            BiometricProfileValue("Partition", value: report.split.title)
            BiometricProfileValue("Current holdout exposures", value: String(descriptor.currentHoldoutUseCount))
            if let warning = report.qualificationWarning { Text(warning).foregroundStyle(Theme.amber) }
            if report.status == .improved { Text("This retained evaluation is not current activation approval or clinical accuracy. Applying a revision checks the evidence and settings again.").font(.footnote).foregroundStyle(Theme.text2) }
            if descriptor.currentHoldoutUseCount > 1 || report.evidence == "reused_holdout_is_validation" {
                Text("Repeated holdout exposure weakens independent evidence. Treat these results as validation, rather than an untouched holdout.").font(.footnote).foregroundStyle(Theme.amber)
            }
            if report.hasStages { BiometricProfileValue("Assumed stage calibration quality", value: ReportDisplay.number(report.calibration.quality)) }
            if report.hasWaveforms { Text("Readings were recomputed from retained waveforms. Original stored readings remain unchanged.").font(.footnote).foregroundStyle(Theme.text2) }
            else if report.protocol.mode == .comparison { Text("Original stored readings were compared. Numerical parameter changes were not replayed.").font(.footnote).foregroundStyle(Theme.text2) }
            DisclosureGroup("Evidence limitations") {
                ForEach(Array(report.limitations.enumerated()), id: \.offset) { _, limitation in Text(limitation).font(.footnote).foregroundStyle(Theme.text2).padding(.top, 6) }
            }
        }.cardStyle()
    }
}

struct BiometricReportIdentityView: View {
    let report: BiometricEvaluationReport
    let descriptor: BiometricReportDescriptor
    var body: some View {
        DisclosureGroup("Report identity") {
            VStack(alignment: .leading, spacing: 12) {
                BiometricProfileIdentity(title: "Complete retained report hash", value: descriptor.contentHash)
                Text("This hash identifies the complete retained report. The summary excludes trace rows.").font(.footnote).foregroundStyle(Theme.text2)
                BiometricProfileIdentity(title: "Dataset hash", value: report.datasetHash)
                BiometricProfileIdentity(title: "Protocol hash", value: report.protocolHash)
                BiometricProfileIdentity(title: "Evaluator build hash", value: report.evaluatorBuildHash)
            }.padding(.top, 8)
        }.cardStyle()
    }
}

enum ReportDisplay {
    static func number(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(0...3))) } ?? "Not scored" }
    static func percent(_ value: Double?) -> String { value.map { $0.formatted(.percent.precision(.fractionLength(0...2))) } ?? "Not scored" }
    static func minutes(_ value: Double) -> String { number(value / 60000) + " min" }
    static func label(_ raw: String) -> String {
        raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).replacingOccurrences(of: "_", with: " ").capitalized
    }
}
