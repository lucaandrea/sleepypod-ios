import SwiftUI

struct BiometricDatasetLibraryScreen: View {
    let model: BiometricDatasetWorkspace
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Inspect frozen inputs and whole-night partitions, or release their retained storage.").font(.footnote).foregroundStyle(Theme.text2)
                BiometricBacktestPendingCard(model: model)
                if model.loading { ProgressView("Loading retained datasets…") }
                if let error = model.loadError { BiometricProfileError(error: error) }
                Button("Reload datasets", systemImage: "arrow.clockwise") { Task { await model.load(model.cursor) } }.disabled(model.loading)
                if let page = model.page {
                    if page.items.isEmpty { Text("No retained datasets for this side.").foregroundStyle(Theme.text2) }
                    ForEach(page.items) { dataset in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(dataset.subjectId).font(.headline)
                            Text(dataset.available ? "Inputs retained" : "Inputs released; metadata retained").foregroundStyle(dataset.available ? Theme.text2 : Theme.amber)
                            BiometricProfileDate(title: "Created", milliseconds: dataset.createdAtMs)
                            Text("Stored bytes: \(dataset.byteLength)").font(.footnote)
                            BiometricProfileIdentity(title: "Dataset", value: dataset.id)
                            NavigationLink { BiometricDatasetDetailScreen(model: model, id: dataset.id) } label: { Label("Inspect dataset", systemImage: "archivebox") }.accessibilityIdentifier("datasets.inspect.\(dataset.id)")
                        }.cardStyle()
                    }
                    if model.cursor != nil { Button("Newest datasets") { Task { await model.load() } }.disabled(model.loading) }
                    if let next = page.nextCursor { Button("Older datasets") { Task { await model.load(next) } }.disabled(model.loading) }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Retained datasets").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("datasets.libraryContent")
            .task { if model.page == nil { await model.load() } }
    }
}

struct BiometricDatasetDetailScreen: View {
    let model: BiometricDatasetWorkspace
    let id: String
    @State private var dataset: BiometricDataset?
    @State private var loading = false
    @State private var error: String?
    @State private var confirmRelease = false
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if loading { ProgressView("Checking retained inputs…") }
                if let error { BiometricProfileError(error: error) }
                Button("Refresh dataset", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
                BiometricBacktestPendingCard(model: model)
                if let dataset {
                    VStack(alignment: .leading, spacing: 12) {
                        ReferenceSideValue(side: dataset.side)
                        BiometricProfileValue("Sleeper identifier", value: dataset.subjectId)
                        Text(dataset.available ? "Inputs retained" : "Inputs released; metadata retained").font(.headline).accessibilityIdentifier("datasets.availability")
                        Text(APIBackend.current.isDemo ? "Demo · synthetic input metadata. No controller data was copied." : dataset.available ? "Retained input integrity checked by the controller." : "Retained inputs are unavailable for new evaluations.").font(.footnote).foregroundStyle(Theme.text2)
                        BiometricProfileIdentity(title: "Dataset", value: dataset.id)
                        BiometricProfileIdentity(title: "Content hash", value: dataset.contentHash)
                        BiometricProfileDate(title: "Created", milliseconds: dataset.createdAtMs)
                        if let released = dataset.releasedAtMs { BiometricProfileDate(title: "Released", milliseconds: released) }
                        Text("Stored bytes: \(dataset.byteLength)").font(.footnote)
                    }.cardStyle().id("dataset.identity")
                    BiometricDatasetManifestView(manifest: dataset.manifest)
                    if dataset.available {
                        Button("Release retained inputs", role: .destructive) { confirmRelease = true }.disabled(!model.canMutate || loading || error != nil).accessibilityIdentifier("datasets.release")
                    }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Frozen input details").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("datasets.detailContent")
            .task(id: id) { await load() }
            .onChange(of: model.receipt) { _, receipt in
                guard let receipt, receipt.id == id, receipt.side == model.side else { return }
                dataset = receipt
                // Bring the confirmed result into view after a release from the bottom of the page.
                withAnimation { scroll.scrollTo("dataset.identity", anchor: .top) }
            }
            .confirmationDialog("Permanently release these retained inputs? Existing reports and audit metadata remain. Active jobs must finish or be cancelled first.", isPresented: $confirmRelease, titleVisibility: .visible) {
                Button("Permanently release inputs", role: .destructive) { if let dataset { Task { await model.release(dataset) } } }.accessibilityIdentifier("datasets.confirmRelease")
                Button("Keep retained inputs", role: .cancel) {}
            }
        }
    }
    private func load() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await model.client.dataset(id: id)
            guard !Task.isCancelled else { return }
            guard result.id == id, result.side == model.side, result.validIdentity else { throw BiometricBacktestInput.error("The returned dataset does not match this selection.") }
            dataset = result
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct BiometricDatasetManifestView: View {
    let manifest: BiometricDatasetManifest
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Whole-night partitions").font(.headline)
                Text(manifest.splitProtocol.evidence == "descriptive_only" ? "Too few independent nights for a validation split. Descriptive evaluation only." : "Whole-night partitions assigned. Biometric performance has not been validated.").font(.footnote).foregroundStyle(Theme.text2)
                BiometricProfileValue("Partition timezone", value: manifest.splitProtocol.timezone)
                if !manifest.supported { BiometricProfileError(error: "This dataset format is not supported for new native evaluations. Metadata remains available.") }
                ForEach(manifest.splitProtocol.assignments) { cohort in
                    DisclosureGroup("\(cohort.nightLabels.joined(separator: ", ")) · \(cohort.split.capitalized)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sessions: \(cohort.sessionIds.map(String.init).joined(separator: ", "))")
                            BiometricProfileValue("Start · UTC", value: ReferenceLabels.utc(cohort.startMs))
                            BiometricProfileValue("End · UTC", value: ReferenceLabels.utc(cohort.endMs))
                            BiometricProfileIdentity(title: "Night identity", value: cohort.cohortId)
                        }.padding(.top, 8)
                    }
                }
                ForEach(manifest.splitProtocol.limitations, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.text2) }
                DisclosureGroup("Grouping version") {
                    BiometricProfileIdentity(title: "Protocol", value: manifest.splitProtocol.version)
                    BiometricProfileIdentity(title: "Grouping", value: manifest.splitProtocol.grouping)
                    BiometricProfileIdentity(title: "Timezone runtime", value: "ICU \(manifest.splitProtocol.timezoneRuntime.icu) · tz \(manifest.splitProtocol.timezoneRuntime.tz)")
                }
            }.cardStyle()
            VStack(alignment: .leading, spacing: 12) {
                Text("Frozen capabilities").font(.headline)
                BiometricProfileValue("Stored-reading comparison", value: manifest.capabilities.comparison ? "Available" : "Unavailable")
                BiometricProfileValue("Stage replay", value: manifest.capabilities.stageReplay ? "Available" : "Unavailable")
                BiometricProfileValue("Waveform replay", value: manifest.capabilities.signalReplay ? "Available" : "Unavailable")
                if let parent = manifest.parentDataset {
                    BiometricProfileIdentity(title: "Parent dataset", value: parent.id)
                    BiometricProfileIdentity(title: "Parent hash", value: parent.contentHash)
                }
                ForEach(manifest.limitations, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.text2) }
            }.cardStyle()
            ForEach(manifest.coverage) { coverage in
                NavigationLink { DatasetCoverageScreen(coverage: coverage) } label: { Label("Session \(coverage.sessionId) · frozen coverage", systemImage: "waveform.path.ecg") }.accessibilityIdentifier("datasets.coverage.\(coverage.sessionId)")
            }
        }
    }
}
struct DatasetCoverageScreen: View {
    let coverage: BiometricDatasetManifest.Coverage
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReplayCoverageCard(title: "Frozen vitals", coverage: coverage.vitals)
                ReplayCoverageCard(title: "Frozen movement", coverage: coverage.movement)
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Frozen coverage").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("datasets.coverageContent")
    }
}
