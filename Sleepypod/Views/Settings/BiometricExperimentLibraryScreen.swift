import SwiftUI

struct BiometricExperimentLibraryScreen: View {
    let model: BiometricDatasetWorkspace
    @State private var library: BiometricExperimentLibrary
    init(model: BiometricDatasetWorkspace) { self.model = model; _library = State(initialValue: .init(side: model.side, client: model.client)) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ReferenceSideValue(side: model.side)
                Text("Saved experiments fix their protocol before evaluation. Holdout access is recorded per experiment; repeated access does not establish independent validation.").font(.footnote).foregroundStyle(Theme.text2)
                BiometricBacktestPendingCard(model: model)
                if let error = library.error { BiometricProfileError(error: error) }
                if library.loading { ProgressView("Loading experiments…") }
                Button("Reload experiments", systemImage: "arrow.clockwise") { Task { await library.load(library.cursor) } }.disabled(library.loading)
                if let page = library.page {
                    if page.items.isEmpty { Text("No saved experiments for this side.").foregroundStyle(Theme.text2) }
                    ForEach(page.items) { experiment in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(experiment.protocol.mode.title).font(.headline)
                            BiometricProfileDate(title: "Created", milliseconds: experiment.createdAtMs)
                            Text("Holdout accesses: \(experiment.holdoutAccesses)")
                            BiometricProfileIdentity(title: "Experiment", value: experiment.id)
                            NavigationLink { BiometricExperimentDetailScreen(model: model, id: experiment.id) } label: { Label("Inspect experiment", systemImage: "flask") }.accessibilityIdentifier("experiments.inspect.\(experiment.id)")
                        }.cardStyle()
                    }
                    if library.cursor != nil { Button("Newest experiments") { Task { await library.load() } }.disabled(library.loading) }
                    if let cursor = page.nextCursor { Button("Older experiments") { Task { await library.load(cursor) } }.disabled(library.loading) }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Saved experiments").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("experiments.libraryContent")
            .task { await library.load(library.cursor) }
    }
}

struct BiometricExperimentDetailScreen: View {
    let model: BiometricDatasetWorkspace
    let id: String
    @State private var experiment: BiometricExperiment?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error { BiometricProfileError(error: error) }
                if loading { ProgressView("Loading frozen protocol…") }
                Button("Refresh experiment", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
                if let experiment {
                    VStack(alignment: .leading, spacing: 10) {
                        ReferenceSideValue(side: experiment.side)
                        BiometricProfileIdentity(title: "Experiment", value: experiment.id)
                        BiometricProfileIdentity(title: "Protocol hash", value: experiment.protocolHash)
                        BiometricProfileDate(title: "Created", milliseconds: experiment.createdAtMs)
                        Text("Holdout accesses: \(experiment.holdoutAccesses)").accessibilityIdentifier("experiments.holdoutAccesses")
                        if APIBackend.current.isDemo { Text("Demo · synthetic protocol; no job has run.").font(.footnote).foregroundStyle(Theme.text2) }
                    }.cardStyle()
                    BiometricExperimentProtocolView(evaluationProtocol: experiment.protocol)
                    NavigationLink { BiometricDatasetDetailScreen(model: model, id: experiment.datasetId) } label: { Label("Inspect frozen inputs", systemImage: "archivebox") }.accessibilityIdentifier("experiments.dataset")
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Experiment details").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("experiments.detailContent")
            .task(id: id) { await load() }
    }
    private func load() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await model.client.experiment(id: id)
            guard !Task.isCancelled else { return }
            guard result.id == id, result.side == model.side, result.validIdentity else { throw BiometricBacktestInput.error("The saved experiment does not match this selection.") }
            experiment = result
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
