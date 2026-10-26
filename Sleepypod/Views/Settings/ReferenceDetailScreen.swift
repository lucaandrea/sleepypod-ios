import SwiftUI

struct ReferenceDetailScreen: View {
    let model: BiometricReferencesWorkspace
    private let initial: ReferenceDescriptor
    @State private var descriptor: ReferenceDescriptor
    @State private var loading = false
    @State private var fresh = false
    @State private var error: String?
    @State private var confirmDelete = false
    init(model: BiometricReferencesWorkspace, initial: ReferenceDescriptor) {
        self.model = model; self.initial = initial; _descriptor = State(initialValue: initial)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(descriptor.summary.source) · revision \(descriptor.revision)").font(.headline)
                Text(descriptor.available ? "Source measurements available" : "Source measurements deleted").foregroundStyle(descriptor.available ? Theme.text2 : Theme.amber).accessibilityIdentifier("references.availability")
                if loading { ProgressView("Reading source status…") }
                if let error { BiometricProfileError(error: error) }
                Button("Refresh source status", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(loading)
                ReferencePendingCard(model: model)
                if descriptor.available {
                    GroupedCard {
                        NavigationLink { ReferenceMeasurementsScreen(client: model.client, descriptor: descriptor) } label: { SettingsRow("Measurements", icon: "waveform.path.ecg", tile: true, chevron: true) }.accessibilityIdentifier("references.measurements")
                        NavigationLink { ReferenceImportScreen(model: model, parent: descriptor) } label: { SettingsRow("Import a correction", icon: "pencil", tile: true, chevron: true) }.disabled(!model.canMutate || !fresh).accessibilityIdentifier("references.correct")
                    }
                }
                ReferenceSummaryCard(summary: descriptor.summary)
                VStack(alignment: .leading, spacing: 12) {
                    BiometricProfileDate(title: "Imported", milliseconds: descriptor.createdAtMs)
                    if let deleted = descriptor.deletedAtMs { BiometricProfileDate(title: "Deleted", milliseconds: deleted) }
                    DisclosureGroup("Revision identity") {
                        VStack(alignment: .leading, spacing: 8) {
                            BiometricProfileIdentity(title: "Import", value: descriptor.id)
                            BiometricProfileIdentity(title: "Family", value: descriptor.familyId)
                            if let previous = descriptor.supersedesImportId { BiometricProfileIdentity(title: "Corrects", value: previous) }
                        }.padding(.top, 8)
                    }
                    if descriptor.available {
                        Button("Delete source measurements", role: .destructive) { confirmDelete = true }.disabled(!model.canMutate || !fresh).accessibilityIdentifier("references.delete")
                    }
                    Text("Deleting a source removes its measurements. Frozen datasets retain their separate copies; corrections never rewrite an earlier revision.").font(.footnote).foregroundStyle(Theme.text2)
                }.cardStyle()
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Reference revision").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("references.detailContent")
            .task { await refresh() }
            .confirmationDialog("Delete \(descriptor.summary.source), revision \(descriptor.revision)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete source measurements", role: .destructive) { Task { await model.delete(descriptor); await refresh() } }.accessibilityIdentifier("references.confirmDelete")
            } message: { Text("Sleeper: \(descriptor.summary.subjectId). This removes the source measurements from the controller. Frozen dataset copies remain separate.") }
    }
    private func refresh() async {
        guard !loading else { return }
        loading = true; fresh = false; error = nil
        defer { loading = false }
        do {
            let value = try await model.client.descriptor(id: initial.id)
            guard !Task.isCancelled else { return }
            guard value.id == initial.id, value.summary == initial.summary else { throw ReferenceTextError(message: "The returned source identity does not match this revision.") }
            descriptor = value; fresh = true
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct ReferenceMeasurementsScreen: View {
    let client: any BiometricReferencesServing
    let descriptor: ReferenceDescriptor
    @State private var page: ReferenceMeasurementPage?
    @State private var cursor = 0
    @State private var previous: [Int] = []
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Normalized source records, without interpolation. Exact timestamps below are UTC; an excluded record is retained but cannot be scored.").font(.footnote).foregroundStyle(Theme.text2)
                Button("Reload measurements", systemImage: "arrow.clockwise") { Task { await load(cursor) } }.disabled(loading)
                if loading { ProgressView("Reading measurements…") }
                if let error { BiometricProfileError(error: error) }
                if let page {
                    if page.items.isEmpty { Text("No measurements on this page.").foregroundStyle(Theme.text2) }
                    ForEach(page.items) { row in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(ReferenceLabels.metric(row.metric)).font(.headline)
                            Text(row.stage?.capitalized ?? "\(row.value?.formatted() ?? "Unavailable") \(row.unit)").font(.title3.monospacedDigit())
                            Text(row.scorable ? "Eligible for compatible comparison" : "Excluded from scoring").foregroundStyle(row.scorable ? Theme.text2 : Theme.amber)
                            BiometricProfileValue("Start · UTC", value: ReferenceLabels.utc(row.startMs))
                            if row.temporalKind == "interval" { BiometricProfileValue("End · UTC", value: ReferenceLabels.utc(row.endMs)) }
                            BiometricProfileValue("Measurement type", value: "\(row.temporalKind) · \(row.aggregation.replacingOccurrences(of: "_", with: " "))")
                            if let window = row.windowMs { BiometricProfileValue("Window", value: "\(window.formatted()) ms") }
                            if let quality = row.quality { BiometricProfileValue("Source quality", value: quality.formatted()) }
                            ForEach(row.exclusions, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).font(.footnote).foregroundStyle(Theme.amber) }
                            DisclosureGroup("Original source record") { Text(row.original.formattedJSON).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 8) }
                        }.cardStyle()
                    }
                    if let prior = previous.last { Button("Previous measurements") { Task { await load(prior, direction: -1) } }.disabled(loading) }
                    if let next = page.nextCursor { Button("More measurements") { Task { await load(next, direction: 1) } }.disabled(loading) }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Measurements").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("references.measurementsContent")
            .task { await load(cursor) }
    }
    private func load(_ after: Int, direction: Int = 0) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let value = try await client.measurements(id: descriptor.id, after: after)
            guard !Task.isCancelled else { return }
            if direction > 0 { previous.append(cursor) } else if direction < 0 { _ = previous.popLast() }
            page = value; cursor = after
        } catch { if !Task.isCancelled { self.error = error.localizedDescription; page = nil } }
    }
}
