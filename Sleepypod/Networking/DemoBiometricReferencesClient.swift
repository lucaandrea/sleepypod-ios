import Foundation

struct ReferenceDemoFixture: Decodable, Sendable {
    let corrected: Bool
    let input: ReferenceImportInput
    let summary: ReferencePreview
    let measurements: [ReferenceMeasurement]
    static func load(side: Side, corrected: Bool = false) throws -> Self {
        guard let url = Bundle.main.url(forResource: "reference-demo", withExtension: "json"),
              let value = try JSONDecoder().decode([Self].self, from: Data(contentsOf: url)).first(where: { $0.input.side == side && $0.corrected == corrected }) else {
            throw ReferenceTextError(message: "The bundled reference example is unavailable.")
        }
        return value
    }
}

/// Only bundled synthetic rows have Core-generated normalization. Arbitrary imports require a controller.
actor DemoBiometricReferencesClient: BiometricReferencesServing {
    nonisolated let scope = "demo-biometric-references"
    private var imports: [ReferenceDescriptor] = []
    private var normalized: [String: [ReferenceMeasurement]] = [:]
    private func fixture(_ input: ReferenceImportInput) throws -> ReferenceDemoFixture {
        for corrected in [false, true] {
            let fixture = try ReferenceDemoFixture.load(side: input.side, corrected: corrected)
            if fixture.input == input { return fixture }
        }
        throw ReferenceTextError(message: "Demo supports the bundled synthetic example. Connect to your controller to preview your own measurements.")
    }
    func preview(_ input: ReferenceImportInput) throws -> ReferencePreview { try fixture(input).summary }
    func commit(_ request: ReferenceCommit) throws -> ReferenceDescriptor {
        let fixture = try fixture(request.input)
        guard request.previewHash == fixture.summary.contentHash, fixture.summary.rejected == 0 || request.acceptRejectedRows else { throw ReferenceTextError(message: "Review this exact example and acknowledge omitted rows before saving.") }
        if let found = imports.first(where: { request.matches($0) && $0.available }) { return described(found, alreadyImported: true) }
        let parent = try request.supersedesImportId.map { try descriptor(id: $0) }
        if let parent {
            guard parent.available, parent.summary.side == request.input.side, parent.summary.source == request.input.source,
                  parent.summary.subjectId == request.input.subjectId,
                  imports.filter({ $0.familyId == parent.familyId && $0.available }).max(by: { $0.revision < $1.revision })?.id == parent.id else {
                throw ReferenceTextError(message: "Use the latest available revision with the same source and sleeper mapping.")
            }
        }
        let family = parent?.familyId ?? UUID().uuidString
        let descriptor = ReferenceDescriptor(id: UUID().uuidString, familyId: family,
                                             revision: (imports.filter { $0.familyId == family }.map(\.revision).max() ?? 0) + 1,
                                             supersedesImportId: parent?.id, summary: fixture.summary, createdAtMs: Date.now.timeIntervalSince1970 * 1000,
                                             deletedAtMs: nil, available: true, alreadyImported: false)
        imports.append(descriptor); normalized[descriptor.id] = fixture.measurements
        return descriptor
    }
    func library(side: Side, cursor: ReferenceLibraryPage.Cursor?) -> ReferenceLibraryPage {
        let values = imports.filter { value in
            value.summary.side == side && (cursor == nil || value.createdAtMs < cursor!.createdAtMs || value.createdAtMs == cursor!.createdAtMs && value.id < cursor!.id)
        }.sorted { $0.createdAtMs == $1.createdAtMs ? $0.id > $1.id : $0.createdAtMs > $1.createdAtMs }
        let items = Array(values.prefix(50))
        return .init(items: items, nextCursor: values.count > 50 ? items.last.map { .init(createdAtMs: $0.createdAtMs, id: $0.id) } : nil)
    }
    func descriptor(id: String) throws -> ReferenceDescriptor {
        guard let result = imports.first(where: { $0.id == id }) else { throw ReferenceTextError(message: "Reference import not found.") }
        return described(result)
    }
    func measurements(id: String, after: Int) throws -> ReferenceMeasurementPage {
        guard try descriptor(id: id).available else { throw ReferenceTextError(message: "These source measurements were deleted.") }
        let rows = (normalized[id] ?? []).filter { $0.id > after }
        let items = Array(rows.prefix(100)); return .init(items: items, nextCursor: rows.count > 100 ? items.last?.id : nil)
    }
    func delete(id: String) throws -> ReferenceDeletion {
        let current = try descriptor(id: id)
        if let deleted = current.deletedAtMs { return .init(id: id, deletedAtMs: deleted) }
        let timestamp = Date.now.timeIntervalSince1970 * 1000
        let deleted = ReferenceDescriptor(id: current.id, familyId: current.familyId, revision: current.revision, supersedesImportId: current.supersedesImportId,
                                          summary: current.summary, createdAtMs: current.createdAtMs, deletedAtMs: timestamp, available: false, alreadyImported: nil)
        imports.removeAll { $0.id == id }; imports.append(deleted); normalized[id] = nil
        return .init(id: id, deletedAtMs: timestamp)
    }
    private func described(_ value: ReferenceDescriptor, alreadyImported: Bool? = nil) -> ReferenceDescriptor {
        .init(id: value.id, familyId: value.familyId, revision: value.revision, supersedesImportId: value.supersedesImportId, summary: value.summary,
              createdAtMs: value.createdAtMs, deletedAtMs: value.deletedAtMs, available: value.available, alreadyImported: alreadyImported)
    }
}
