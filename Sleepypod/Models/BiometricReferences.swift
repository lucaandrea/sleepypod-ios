import Foundation

struct ReferenceImportInput: Codable, Equatable, Sendable {
    let side: Side
    let subjectId: String
    let source: String
    let rows: [JSONValue]
    func validated() throws -> Self {
        guard (1...200).contains(subjectId.utf16.count), (1...120).contains(source.utf16.count), (1...2000).contains(rows.count) else {
            throw ReferenceTextError(message: "Enter a sleeper identifier, source and 1–2000 records.")
        }
        var pending: [(value: JSONValue, depth: Int)] = [(.array(rows), 1)]
        var nodes = 4
        while let entry = pending.popLast() {
            nodes += 1
            guard nodes <= 100000, entry.depth <= 12 else { throw ReferenceTextError(message: "Reference JSON is too large or deeply nested.") }
            switch entry.value {
            case .array(let values): pending.append(contentsOf: values.map { ($0, entry.depth + 1) })
            case .object(let fields): pending.append(contentsOf: fields.values.map { ($0, entry.depth + 1) })
            case .number(let value): if !value.isFinite { throw ReferenceTextError(message: "Reference values must be finite JSON numbers.") }
            default: break
            }
        }
        guard try JSONEncoder().encode(self).count <= ReferenceTextParser.maximumBytes else {
            throw ReferenceTextError(message: "The complete reference import exceeds 2 MiB.")
        }
        return self
    }
}

struct ReferencePreview: Codable, Equatable, Sendable {
    struct TimePolicy: Codable, Equatable, Sendable {
        let timezone: String?
        let utcOffsetMinutes: Int?
        let disambiguation: String
    }
    struct Rejection: Codable, Equatable, Sendable { let row: Int; let code: String; let message: String }
    let contentHash: String
    let adapterVersion: String
    let side: Side
    let subjectId: String
    let source: String
    let timePolicy: TimePolicy
    let received: Int
    let accepted: Int
    let rejected: Int
    let duplicates: Int
    let unscorable: Int
    let conflicts: Int
    let startMs: Double?
    let endMs: Double?
    let metrics: [String]
    let rejectionCounts: [String: Int]
    let rejectionExamples: [Rejection]
    let warnings: [String]
    func matches(_ input: ReferenceImportInput) -> Bool {
        side == input.side && subjectId == input.subjectId && source == input.source && received == input.rows.count
            && contentHash.count == 64 && contentHash.allSatisfy { "0123456789abcdef".contains($0) }
            && accepted >= 0 && rejected >= 0 && duplicates >= 0 && accepted + rejected + duplicates == received
    }
}

struct ReferenceDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let familyId: String
    let revision: Int
    let supersedesImportId: String?
    let summary: ReferencePreview
    let createdAtMs: Double
    let deletedAtMs: Double?
    let available: Bool
    let alreadyImported: Bool?
}

struct ReferenceLibraryPage: Codable, Sendable {
    struct Cursor: Codable, Equatable, Sendable { let createdAtMs: Double; let id: String }
    let items: [ReferenceDescriptor]
    let nextCursor: Cursor?
}

struct ReferenceMeasurement: Codable, Identifiable, Sendable {
    let id: Int
    let recordKey: String
    let metric: String
    let value: Double?
    let stage: String?
    let unit: String
    let startMs: Double
    let endMs: Double
    let temporalKind: String
    let aggregation: String
    let windowMs: Double?
    let quality: Double?
    let scorable: Bool
    let exclusions: [String]
    let original: JSONValue
}
struct ReferenceMeasurementPage: Codable, Sendable { let items: [ReferenceMeasurement]; let nextCursor: Int? }
struct ReferenceDeletion: Codable, Sendable { let id: String; let deletedAtMs: Double? }

struct ReferenceCommit: Codable, Equatable, Sendable {
    let input: ReferenceImportInput
    let previewHash: String
    let acceptRejectedRows: Bool
    let supersedesImportId: String?
    enum CodingKeys: String, CodingKey { case input = "import", previewHash, acceptRejectedRows, supersedesImportId }
    func matches(_ descriptor: ReferenceDescriptor) -> Bool {
        descriptor.summary.matches(input) && descriptor.summary.contentHash == previewHash
            && descriptor.supersedesImportId == supersedesImportId
    }
}

enum ReferenceLabels {
    static func metric(_ raw: String) -> String {
        switch raw {
        case "heart_rate": "Heart rate"
        case "breathing_rate": "Breathing rate"
        case "window_ibi_variability_v1": "Window IBI variability"
        case "hrv_rmssd": "HRV · RMSSD"
        case "hrv_sdnn": "HRV · SDNN"
        case "hrv_unknown": "HRV · definition unknown"
        case "sleep_stages": "Sleep stages"
        default: raw.replacingOccurrences(of: "_", with: " ")
        }
    }
    static func utc(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite else { return "Unavailable" }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}
