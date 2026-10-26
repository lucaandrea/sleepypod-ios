import SwiftUI

struct BiometricBacktestJobsScreen: View {
    let model: BiometricDatasetWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var library: BiometricBacktestJobLibrary
    init(model: BiometricDatasetWorkspace) { self.model = model; _library = State(initialValue: .init(side: model.side, client: model.client)) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: model.side)
                Text("Execution state is separate from the strength of biometric evidence.").font(.footnote).foregroundStyle(Theme.text2)
                BiometricBacktestPendingCard(model: model)
                if let error = library.error { BiometricProfileError(error: error) }
                if library.loading && library.page == nil { ProgressView("Loading jobs…") }
                Button("Refresh jobs", systemImage: "arrow.clockwise") { Task { await library.load(library.cursor) } }.disabled(library.loading)
                if let page = library.page {
                    if page.items.isEmpty { Text("No evaluation jobs for this side.").foregroundStyle(Theme.text2) }
                    ForEach(page.items) { job in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(job.state.title).font(.headline)
                            Text("\(job.split.title) · \(job.evaluationScope.title)")
                            Text("Attempt \(job.attempt)").font(.footnote).foregroundStyle(Theme.text2)
                            BiometricProfileIdentity(title: "Job", value: job.id)
                            NavigationLink { BiometricBacktestJobScreen(model: model, id: job.id) } label: { Label("Inspect job", systemImage: "list.bullet.rectangle") }.accessibilityIdentifier("jobs.inspect.\(job.id)")
                        }.cardStyle()
                    }
                    if library.cursor != nil { Button("Newest jobs") { Task { await library.load() } }.disabled(library.loading) }
                    if let next = page.nextCursor { Button("Older jobs") { Task { await library.load(next) } }.disabled(library.loading) }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Evaluation jobs").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("jobs.libraryContent")
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if !library.loading { await library.load(library.cursor) }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }
}

struct BiometricBacktestJobScreen: View {
    let model: BiometricDatasetWorkspace
    let id: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var job: BiometricBacktestJob?
    @State private var error: String?
    @State private var loading = false
    @State private var confirmCancel = false
    @State private var readGeneration = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error { BiometricProfileError(error: error) }
                if loading && job == nil { ProgressView("Loading job…") }
                Button("Refresh job", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
                if let job {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(job.state.title).font(.title2).accessibilityIdentifier("jobs.state")
                        Text("\(job.split.title) · \(job.evaluationScope.title)")
                        Text("Attempt \(job.attempt)")
                        if job.progress.totalNights > 0 {
                            ProgressView(value: Double(job.progress.completedNights), total: Double(job.progress.totalNights))
                            Text("\(job.progress.completedNights) of \(job.progress.totalNights) nights completed")
                        } else { Text("Night progress is not available yet.").foregroundStyle(Theme.text2) }
                        Text(job.progress.phase.replacingOccurrences(of: "_", with: " ")).font(.footnote).foregroundStyle(Theme.text2)
                        if let failure = job.error { BiometricProfileError(error: failure) }
                        if job.state == .queued { Text("Waiting for a worker and resource admission. No execution is implied by this queued request.").font(.footnote).foregroundStyle(Theme.text2) }
                        if job.state == .cancellationRequested { Text("The worker has not yet confirmed that it stopped.").font(.footnote).foregroundStyle(Theme.text2) }
                        if job.state == .succeeded { Text("Execution completed. Review its retained report before drawing conclusions about agreement or improvement.").font(.footnote).foregroundStyle(Theme.text2) }
                        if APIBackend.current.isDemo { Text("Demo · synthetic request only. No worker, replay evidence or profile adoption is simulated.").font(.footnote).foregroundStyle(Theme.text2) }
                    }.cardStyle()
                    if job.state.cancellable {
                        Button("Cancel evaluation", role: .destructive) { confirmCancel = true }.disabled(!model.canMutate || loading || error != nil).accessibilityIdentifier("jobs.cancel")
                    }
                    if job.state == .succeeded {
                        NavigationLink { BiometricReportScreen(model: model, job: job) } label: { Label("Inspect evaluation report", systemImage: "chart.xyaxis.line") }.accessibilityIdentifier("jobs.report")
                    }
                    BiometricBacktestJobInputs(job: job)
                    NavigationLink { BiometricExperimentDetailScreen(model: model, id: job.experimentId) } label: { Label("Inspect experiment", systemImage: "flask") }
                }
                BiometricBacktestPendingCard(model: model)
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Evaluation job").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("jobs.detailContent")
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await load()
                    if job?.state.terminal == true { return }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            // A cancellation receipt supersedes any earlier in-flight poll.
            .onChange(of: model.jobReceipt) { _, receipt in if let receipt, receipt.id == id { readGeneration += 1; job = receipt } }
            .confirmationDialog("Cancel this evaluation? Job history and any holdout exposure remain.", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel evaluation", role: .destructive) { if let job { Task { await model.cancelJob(job) } } }.accessibilityIdentifier("jobs.confirmCancel")
                Button("Keep evaluation", role: .cancel) {}
            }
    }
    private func load() async {
        guard !loading else { return }; loading = true; readGeneration += 1; let generation = readGeneration
        defer { loading = false }
        do {
            let result = try await model.client.job(id: id)
            let experiment = try await model.client.experiment(id: result.experimentId)
            guard !Task.isCancelled, generation == readGeneration else { return }
            guard result.id == id, result.validIdentity, experiment.validIdentity, experiment.id == result.experimentId,
                  experiment.side == model.side, experiment.datasetId == result.datasetId else { throw BiometricBacktestInput.error("The job identity does not match this bed side and experiment.") }
            if let job, !BiometricBacktestJobIdentity(side: model.side, job: job).matches(result) { throw BiometricBacktestInput.error("The job's frozen inputs changed. Reopen the job library.") }
            job = result; error = nil
        } catch { if !Task.isCancelled, generation == readGeneration { self.error = error.localizedDescription } }
    }
}

struct BiometricBacktestJobInputs: View {
    let job: BiometricBacktestJob
    var body: some View {
        DisclosureGroup("Pinned job inputs") {
            VStack(alignment: .leading, spacing: 10) {
                BiometricProfileIdentity(title: "Job", value: job.id)
                BiometricProfileIdentity(title: "Dataset", value: job.datasetId)
                BiometricProfileIdentity(title: "Dataset hash", value: job.datasetHash)
                BiometricProfileIdentity(title: APIBackend.current.isDemo ? "Synthetic queue identity · no evaluator" : "Evaluator build hash", value: job.evaluatorBuildHash)
                ForEach(job.configurations) { configuration in
                    BiometricProfileIdentity(title: configuration.label == "current" ? (job.evaluationScope == .waveform ? "Current baseline" : "Current stage view") : configuration.label.capitalized, value: configuration.hash)
                    if let revision = configuration.revisionId { BiometricProfileIdentity(title: "Revision", value: revision) }
                }
                BiometricProfileDate(title: "Created", milliseconds: job.createdAtMs)
                BiometricProfileDate(title: "Last job update", milliseconds: job.updatedAtMs)
            }.padding(.top, 8)
        }.cardStyle().accessibilityIdentifier("jobs.inputs")
    }
}
