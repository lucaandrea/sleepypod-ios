import Foundation
import Observation

@MainActor @Observable final class ReferenceImportWorkspace {
    let side: Side
    let parent: ReferenceDescriptor?
    let client: any BiometricReferencesServing
    var subject = "" { didSet { invalidate() } }
    var source = "" { didSet { invalidate() } }
    var text = "" { didSet { invalidate() } }
    var format = ReferenceTextParser.Format.csv { didSet { invalidate() } }
    var acceptRejected = false
    private(set) var preview: ReferencePreview?
    private(set) var reviewedInput: ReferenceImportInput?
    private(set) var busy = false
    private(set) var error: String?
    private var revision = 0
    init(side: Side, client: any BiometricReferencesServing, parent: ReferenceDescriptor? = nil) {
        self.side = side; self.client = client; self.parent = parent
        if let parent { subject = parent.summary.subjectId; source = parent.summary.source }
    }
    private func invalidate() { revision += 1; preview = nil; reviewedInput = nil; acceptRejected = false; error = nil }
    func review() async {
        guard !busy else { return }
        busy = true; error = nil; preview = nil; reviewedInput = nil; acceptRejected = false
        let stamp = revision
        defer { busy = false }
        do {
            let mappedSubject = parent?.summary.subjectId ?? subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let mappedSource = parent?.summary.source ?? source.trimmingCharacters(in: .whitespacesAndNewlines)
            let input = try ReferenceImportInput(side: side, subjectId: mappedSubject, source: mappedSource, rows: ReferenceTextParser.parse(text, format: format)).validated()
            if let parent {
                guard parent.available, parent.summary.side == side, parent.summary.subjectId == subject, parent.summary.source == source else { throw ReferenceTextError(message: "A correction must retain the original side, sleeper and source.") }
                let current = try await client.descriptor(id: parent.id)
                guard current.id == parent.id, current.available, current.summary == parent.summary else { throw ReferenceTextError(message: "The corrected source is unavailable or changed. Reload the library.") }
            }
            let result = try await client.preview(input)
            guard stamp == revision, !Task.isCancelled else { return }
            guard result.matches(input) else { throw ReferenceTextError(message: "The preview does not match this import. Review again.") }
            preview = result; reviewedInput = input
        } catch { if stamp == revision, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func request() throws -> ReferenceCommit {
        guard !busy, let preview, let reviewedInput, preview.accepted > 0, preview.rejected == 0 || acceptRejected else { throw ReferenceTextError(message: "Review the exact import and acknowledge any omitted rows before saving.") }
        return .init(input: reviewedInput, previewHash: preview.contentHash, acceptRejectedRows: acceptRejected, supersedesImportId: parent?.id)
    }
    func loadFile(_ url: URL) async {
        guard !busy else { return }
        busy = true; error = nil
        let stamp = revision
        defer { busy = false }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: ReferenceTextParser.maximumBytes + 1) ?? Data()
                guard data.count <= ReferenceTextParser.maximumBytes, let value = String(data: data, encoding: .utf8) else { throw ReferenceTextError(message: "Choose a UTF-8 CSV or JSON file no larger than 2 MiB.") }
                return value
            }.value
            guard stamp == revision, !Task.isCancelled else { return }
            format = url.pathExtension.lowercased() == "json" ? .json : .csv; text = loaded
        } catch { if stamp == revision, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func loadSample(_ fixture: ReferenceDemoFixture) {
        format = .json; subject = fixture.input.subjectId; source = fixture.input.source
        text = JSONValue.array(fixture.input.rows).formattedJSON
    }
}
