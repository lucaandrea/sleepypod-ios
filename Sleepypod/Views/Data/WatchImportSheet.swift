import SwiftUI
import UniformTypeIdentifiers

struct WatchImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UserProfile.self) private var profile
    @Environment(SettingsManager.self) private var settings
    @State private var model: WatchImportWorkspace
    @State private var chooseFile = false
    @State private var review = false
    private let demo: Bool
    private let onImported: () async -> Void
    init(side: Side, onImported: @escaping () async -> Void = {}) {
        let backend = APIBackend.current; demo = backend.isDemo
        _model = State(initialValue: WatchImportWorkspace(side: side, client: backend.isDemo ? DemoWatchReferenceClient() : CoreWatchReferenceClient()))
        self.onImported = onImported
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(settings.sideName(for: model.side)) · \(model.side.rawValue) side").font(.headline)
                        Text("Use this sleeper’s Apple Health export. Imported Watch readings stay separate from the Pod’s measurements.")
                        Text("Destination: \(model.destination)").font(.footnote).foregroundStyle(Theme.text2).textSelection(.enabled)
                    }.cardStyle()
                    if model.side == profile.defaultSide {
                        NavigationLink {
                            HealthWatchImportView(side: model.side, onImported: onImported)
                        } label: {
                            Label("Import directly from this iPhone", systemImage: "heart.text.clipboard")
                        }.disabled(model.uploading || model.preparing).cardStyle()
                    }
                    DisclosureGroup("Or use an Apple Health export") {
                        Text("In Health, tap your profile picture, choose Export All Health Data, and save the ZIP to Files. You can also choose an extracted export.xml.")
                            .padding(.top, 10)
                    }.cardStyle()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("The entire selected file is sent to your controller. It imports Watch heart rate and sleep stages, plus breathing and SDNN HRV on supported versions, then removes the uploaded file. Other Health data is not imported.")
                        Text("ZIP or XML · up to 512 MiB · previously imported records are skipped.").foregroundStyle(Theme.text2)
                        if demo { Text("Demo mode never uploads files. Connect to your controller to import your export.").foregroundStyle(Theme.text2) }
                        Button("Choose Health export", systemImage: "doc.badge.plus") { chooseFile = true }.disabled(demo || model.uploading || model.preparing)
                        if let file = model.file { Text("\(file.name) · \(file.size)").font(.footnote).fixedSize(horizontal: false, vertical: true) }
                        Picker("Import period", selection: $model.period) { ForEach(WatchImportPeriod.allCases) { Text($0.title).tag($0) } }
                            .disabled(model.uploading || model.preparing)
                        Button("Review upload", systemImage: "arrow.up.doc") { review = true }
                            .disabled(demo || model.file == nil || model.uploading || model.preparing)
                            .accessibilityIdentifier("watch.reviewUpload")
                    }.font(.subheadline).cardStyle()
                    if model.preparing { ProgressView("Preparing file…") }
                    if model.uploading {
                        ProgressView(value: model.progress)
                        Text(model.progress < 1 ? "Uploading · \(Int(model.progress * 100))%" : "Importing on the Pod… Keep this screen open.")
                            .font(.subheadline)
                        Button("Cancel upload") { model.cancel() }
                    }
                    if let result = model.result { resultCard(result) }
                    if let error = model.error { Text(error).foregroundStyle(Theme.amber).font(.footnote).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: 680).padding(16).frame(maxWidth: .infinity)
            }.background(Theme.background).navigationTitle("Import Apple Watch data").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(model.uploading || model.preparing) } }
                .interactiveDismissDisabled(model.uploading || model.preparing)
                .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.zip, .xml]) { result in
                    switch result {
                    case .success(let url): Task { await model.prepare(url) }
                    case .failure(let error): model.error = error.localizedDescription
                    }
                }
                .confirmationDialog("Upload Health export?", isPresented: $review, titleVisibility: .visible) {
                    Button("Upload to this controller") { model.start() }
                } message: {
                    Text("Send all of \(model.file?.name ?? "the selected file") to \(model.destination) and import the \(model.period.title.lowercased()) for \(settings.sideName(for: model.side)) (\(model.side.rawValue)). The file may contain other private Health information.")
                }
                .onChange(of: model.result != nil) { if model.result != nil { Task { await onImported() } } }
                .onDisappear { model.cleanup() }
        }
    }
    private func resultCard(_ result: WatchImportResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Import complete", systemImage: "checkmark.circle").font(.headline).foregroundStyle(Theme.green)
            Text("\(result.vitals) heart-rate samples · \(result.stages) sleep-stage segments")
            if let breathing = result.breathing, let hrv = result.hrv { Text("\(breathing) breathing samples · \(hrv) SDNN HRV samples") }
            else { Text("This controller’s importer reports heart rate and stages only.").foregroundStyle(Theme.text2) }
            Text("Found \(result.matchedVitals) heart-rate samples and \(result.matchedStages) stages in this period. Previously imported records were skipped.").foregroundStyle(Theme.text2)
            if result.rejectedStageBatches > 0 { Text("\(result.rejectedStageBatches) stage batches conflicted with stored stages and were skipped.").foregroundStyle(Theme.amber) }
        }.font(.subheadline).cardStyle()
    }
}
