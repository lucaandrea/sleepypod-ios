import SwiftUI

struct BiometricBacktestSubmissionScreen: View {
    let model: BiometricDatasetWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var preparation: BiometricBacktestPreparation
    init(model: BiometricDatasetWorkspace, experiment: BiometricExperiment) {
        self.model = model; _preparation = State(initialValue: .init(side: model.side, experiment: experiment, client: model.client))
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: model.side)
                Text("Choose a candidate and partition. The controller captures the default, current baseline and candidate configurations when it accepts this request.").font(.footnote).foregroundStyle(Theme.text2)
                if APIBackend.current.isDemo { Text("Demo · records a synthetic queued request only. No worker runs, no evidence is produced and no profile changes.").font(.footnote).foregroundStyle(Theme.text2) }
                if let error = preparation.error { BiometricProfileError(error: error) }
                Button("Refresh baseline", systemImage: "arrow.clockwise") { Task { await preparation.refresh() } }.disabled(preparation.refreshing)
                if let draft = preparation.draft {
                    candidateLibrary(draft)
                    selection(draft)
                } else if preparation.refreshing { ProgressView("Checking retained inputs…") }
                BiometricBacktestPendingCard(model: model)
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Prepare evaluation").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("jobs.preparationContent")
            .task { await preparation.load() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await preparation.refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }
    private func candidateLibrary(_ draft: BiometricBacktestSubmissionDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Candidate revision").font(.headline)
            if let error = preparation.pageError { BiometricProfileError(error: error) }
            if preparation.loading { ProgressView("Loading candidates…") }
            Button("Reload candidates") { Task { await preparation.load(preparation.cursor) } }.disabled(preparation.loading)
            if let page = preparation.page {
                if page.items.isEmpty { Text("No saved candidate revisions. Create one in Profiles, then return here.").foregroundStyle(Theme.text2) }
                ForEach(page.items) { revision in
                    Button { preparation.select(revision) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Revision \(revision.revision)", systemImage: draft.candidate?.id == revision.id ? "checkmark.circle.fill" : "circle")
                            Text(revision.id).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.text2)
                        }.multilineTextAlignment(.leading)
                    }.disabled(!preparation.fresh()).accessibilityIdentifier("jobs.candidate.\(revision.id)")
                }
                if preparation.cursor != nil { Button("Newest candidates") { Task { await preparation.load() } }.disabled(preparation.loading) }
                if let next = page.nextCursor { Button("Older candidates") { Task { await preparation.load(next) } }.disabled(preparation.loading) }
            }
        }.cardStyle()
    }
    private func selection(_ draft: BiometricBacktestSubmissionDraft) -> some View {
        @Bindable var draft = draft
        return TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 18) {
                if let candidate = draft.candidate {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Selected candidate").font(.headline)
                        BiometricProfileIdentity(title: "Revision", value: candidate.id)
                        BiometricProfileIdentity(title: "Configuration hash", value: candidate.hash)
                        Text("Reviewed profile generation: \(candidate.generation)")
                        if candidate.generation != preparation.overview?.desired.binding.generation {
                            Text("Profile settings changed. Prepare and acknowledge a new request before queueing.").font(.footnote).foregroundStyle(Theme.amber)
                            Button("Prepare with current baseline") { Task { await preparation.prepareCurrentBaseline() } }.disabled(!preparation.fresh())
                        }
                    }.cardStyle()
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Evaluation partition").font(.headline)
                    ForEach(draft.availableSplits, id: \.self) { split in
                        Button { draft.split = split } label: { Label(split.title, systemImage: draft.split == split ? "checkmark.circle.fill" : "circle") }.accessibilityIdentifier("jobs.split.\(split.rawValue)")
                    }
                    if draft.split == .holdout {
                        Toggle("Expose this holdout", isOn: Binding(get: { draft.holdoutAcknowledged }, set: { draft.acknowledgeHoldout($0) })).accessibilityIdentifier("jobs.holdout")
                        Text("Repeated use, including overlapping datasets, weakens held-out evidence. Changing the candidate, baseline or partition requires a new acknowledgment.").font(.footnote).foregroundStyle(Theme.text2)
                    }
                    Text("Retained inputs are checked again before queueing. Stored readings cannot validate numerical parameter changes.").font(.footnote).foregroundStyle(Theme.text2)
                    if !preparation.fresh() { Text("The current baseline needs a successful refresh.").font(.footnote).foregroundStyle(Theme.amber) }
                }.cardStyle()
                if let review = try? preparation.review() {
                    NavigationLink { BiometricBacktestReviewScreen(model: model, review: review) } label: { Label("Review evaluation request", systemImage: "checklist") }
                        .disabled(!model.canMutate).accessibilityIdentifier("jobs.review")
                } else { Text("Select a candidate, a supported partition and any required holdout acknowledgment to continue.").font(.footnote).foregroundStyle(Theme.text2) }
            }
        }
    }
}

struct BiometricBacktestReviewScreen: View {
    let model: BiometricDatasetWorkspace
    @State private var review: BiometricBacktestReview
    init(model: BiometricDatasetWorkspace, review: BiometricBacktestReview) { self.model = model; _review = State(initialValue: review) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: review.side)
                if APIBackend.current.isDemo { Text("Demo · queue bookkeeping only; no evaluation runs.").font(.footnote).foregroundStyle(Theme.text2) }
                BiometricBacktestReviewContent(review: review)
                Button("Queue evaluation") { Task { await model.submitJob(review) } }.buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                    .disabled(!model.canMutate || model.savedJobRequest == review.request).accessibilityIdentifier("jobs.queue")
                BiometricBacktestPendingCard(model: model)
                if let job = model.savedJob, model.savedJobRequest == review.request {
                    NavigationLink { BiometricBacktestJobScreen(model: model, id: job.id) } label: { Label("Inspect saved job", systemImage: "list.bullet.rectangle") }.accessibilityIdentifier("jobs.inspectSaved")
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Review evaluation").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("jobs.reviewContent")
    }
}

struct BiometricBacktestReviewContent: View {
    let review: BiometricBacktestReview
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(review.scope.title).font(.headline)
            BiometricProfileValue("Partition", value: review.request.split.title)
            Text("Expected profile generation: \(review.request.expectedBindingGeneration)")
            if review.request.split == .holdout { Text("Holdout exposure acknowledged for this exact selection.").font(.footnote) }
            BiometricProfileIdentity(title: "Experiment", value: review.request.experimentId)
            BiometricProfileIdentity(title: "Protocol hash", value: review.protocolHash)
            BiometricProfileIdentity(title: "Dataset", value: review.datasetId)
            BiometricProfileIdentity(title: "Input hash", value: review.datasetHash)
            BiometricProfileIdentity(title: "Candidate revision", value: review.request.candidateRevisionId)
            BiometricProfileIdentity(title: "Candidate hash", value: review.candidateHash)
            Text("Queueing saves a request. Execution, completion and evidence of improvement are separate. No active profile changes.").font(.footnote).foregroundStyle(Theme.text2)
        }.cardStyle()
    }
}
