import Foundation

protocol BiometricReferencesServing: Sendable {
    var scope: String { get }
    func preview(_ input: ReferenceImportInput) async throws -> ReferencePreview
    func commit(_ request: ReferenceCommit) async throws -> ReferenceDescriptor
    func library(side: Side, cursor: ReferenceLibraryPage.Cursor?) async throws -> ReferenceLibraryPage
    func descriptor(id: String) async throws -> ReferenceDescriptor
    func measurements(id: String, after: Int) async throws -> ReferenceMeasurementPage
    func delete(id: String) async throws -> ReferenceDeletion
}

struct CoreBiometricReferencesClient: BiometricReferencesServing {
    let transport: CoreRESTClient
    var scope: String { transport.endpoint.absoluteString }
    private let root = "biometric-tuning/references"
    func preview(_ input: ReferenceImportInput) async throws -> ReferencePreview {
        try await transport.post("\(root)/preview", body: input.validated(), returning: ReferencePreview.self)
    }
    func commit(_ request: ReferenceCommit) async throws -> ReferenceDescriptor {
        _ = try request.input.validated()
        if let parent = request.supersedesImportId { _ = try identifier(parent) }
        return try await transport.post("\(root)/commit", body: request, returning: ReferenceDescriptor.self)
    }
    func library(side: Side, cursor: ReferenceLibraryPage.Cursor?) async throws -> ReferenceLibraryPage {
        var query = ["side": side.rawValue]
        if let cursor {
            guard cursor.createdAtMs.isFinite, cursor.createdAtMs >= 0, cursor.createdAtMs.rounded() == cursor.createdAtMs else { throw ReferenceTextError(message: "Invalid reference page cursor. Reload the library.") }
            query["beforeId"] = try identifier(cursor.id); query["beforeCreatedAtMs"] = String(format: "%.0f", cursor.createdAtMs)
        }
        return try await transport.get(root, query: query)
    }
    func descriptor(id: String) async throws -> ReferenceDescriptor { try await transport.get("\(root)/\(identifier(id))") }
    func measurements(id: String, after: Int) async throws -> ReferenceMeasurementPage {
        guard after >= 0 else { throw ReferenceTextError(message: "Invalid measurement cursor. Reload the measurements.") }
        return try await transport.get("\(root)/\(identifier(id))/measurements", query: ["afterId": String(after), "limit": "100"])
    }
    func delete(id: String) async throws -> ReferenceDeletion {
        try await transport.delete("\(root)/\(identifier(id))", returning: ReferenceDeletion.self)
    }
    private func identifier(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw ReferenceTextError(message: "Invalid reference identity. Reload the library.") }
        return value
    }
}
