import SwiftUI
import UniformTypeIdentifiers

struct PersonalLearningSourceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let source: Data
    init(source: String) { self.source = Data(source.utf8) }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= PersonalLearningContract.recordBytes else { throw HouseholdFailure.invalid }
        source = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: source) }
}

struct PersonalLearningDetailScreen: View {
    let model: PersonalLearningWorkspace
    let recordId: String
    @State private var exportDocument: PersonalLearningSourceDocument?
    @State private var exporting = false
    @State private var exportNotice: String?
    var body: some View {
        Form {
            PersonalLearningFeedback(model: model)
            if let detail = model.detail, detail.recordId == recordId, model.removal?.phase != .removed {
                let reading = PersonalLearningPresentation.reading(detail)
                Section {
                    Text(reading.title).font(.title3.bold()).accessibilityIdentifier("learning.detailTitle")
                    if detail.redacted {
                        Text("This record’s content was removed. Its preservation receipt remains.").accessibilityIdentifier("learning.removed")
                    } else {
                        ForEach(reading.facts.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(reading.facts[index].0).font(.caption).foregroundStyle(Theme.text2)
                                Text(reading.facts[index].1).font(.body.weight(.semibold))
                            }.accessibilityElement(children: .combine)
                        }
                        if let note = reading.note { Text(note).textSelection(.enabled).accessibilityIdentifier("learning.note") }
                        if reading.facts.isEmpty { Text("This saved file is available to export for review. Its original format is preserved.") }
                    }
                }
                if let payload = detail.payload {
                    Section {
                        DisclosureGroup("Source and original file") {
                            Text("Saved from \(detail.sourceSide.rawValue.capitalized). Ownership of a saved file does not confirm that all its training data belongs to one sleeper.")
                                .font(.footnote).foregroundStyle(Theme.text2)
                            Button("Export original record", systemImage: "square.and.arrow.up") {
                                exportNotice = nil; exportDocument = .init(source: payload); exporting = true
                            }.accessibilityIdentifier("learning.export")
                            Text("Choose where to save your private copy. Exported files remain in the location you choose.")
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }
                }
            } else if !model.busy, model.removal == nil {
                Section { Text("Return to Saved learning and reload to verify this record.").font(.footnote).foregroundStyle(Theme.text2) }
            }
            PersonalLearningRemovalSection(model: model)
            if let exportNotice { Section { Text(exportNotice).accessibilityIdentifier("learning.exportNotice") } }
        }
        .modifier(PersonalLearningAccessCheck(model: model))
        .privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Saved record").navigationBarTitleDisplayMode(.inline)
        .task(id: recordId) { await model.openRecord(recordId) }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "sleepypod-saved-record", onCompletion: { result in
            exportDocument = nil
            switch result {
            case .success: exportNotice = "Your original record was exported."
            case .failure: exportNotice = "The file could not be exported. Open the source section to try again."
            }
        })
        .onChange(of: exporting) { if !exporting { exportDocument = nil } }
        .onChange(of: model.isInvalidated) { if model.isInvalidated { exporting = false; exportDocument = nil; exportNotice = nil } }
        .onChange(of: model.removal?.phase) {
            if model.removal?.phase != .review { exporting = false; exportDocument = nil; exportNotice = nil }
        }
        .onDisappear { model.closeRecord(); exporting = false; exportDocument = nil; exportNotice = nil }
    }
}
