import Foundation

/// Historical custody is separate from training approval and today's physical bed side.
enum PersonalLearningContract {
    static let recordBytes = 8 * 1_024 * 1_024
    static let totalBytes = 128 * 1_024 * 1_024
    static let interpretation = "historical_custody_not_training_approval"
    static let attribution = "operator_custody_unreviewed"
    static let activation = "historical_only"
    static let sources: [String: String] = [
        "comfort_states": "personal", "comfort_feedback": "personal", "journal_entries": "personal",
        "comfort_moments": "personal", "comfort_models": "personal", "comfort_reviews": "personal", "comfort_events": "personal",
        "thermal_forecasts": "physical", "target_response_models": "physical", "side_stage_models": "processing",
        "stage_model_library": "processing", "stage_classifier_changes": "processing",
        "biometric_profile_revisions": "processing", "biometric_profile_bindings": "processing"
    ]
    static func digest(_ value: String) -> Bool { value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
    static func instant(_ value: Int64) -> Bool { value > 0 && value <= 8_640_000_000_000_000 }
    static func calendarDate(_ value: String) -> Bool {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }
    static func envelope(_ version: Int, generatedAt: Int64, interpretation: String, scope: PersonalHistoryScope, session: HouseholdSession) throws {
        guard version == 1, instant(generatedAt), interpretation == self.interpretation else { throw HouseholdFailure.invalid }
        try scope.validate(for: session)
    }
}

struct PersonalLearningArchive: Codable, Equatable, Identifiable, Sendable {
    let archiveId: String
    let capturedAt: Int64
    let sourceSide: Side
    let timeZone: String
    let recordCount: Int
    let payloadBytes: Int
    let contentHash: String
    let attribution: String
    let activation: String
    var id: String { archiveId }
    func validate(generatedAt: Int64) throws {
        guard HouseholdValidation.identifier(archiveId), PersonalLearningContract.instant(capturedAt), capturedAt <= generatedAt,
              !timeZone.isEmpty, timeZone.utf16.count <= 100, (0...100_000).contains(recordCount),
              (0...PersonalLearningContract.totalBytes).contains(payloadBytes), PersonalLearningContract.digest(contentHash),
              attribution == PersonalLearningContract.attribution, activation == PersonalLearningContract.activation else { throw HouseholdFailure.invalid }
    }
}

struct PersonalLearningRecord: Codable, Equatable, Identifiable, Sendable {
    let recordId: String
    let ordinal: Int
    let sourceTable: String
    let sourceSide: Side
    let kind: String
    let payloadBytes: Int
    let redacted: Bool
    let recordedDate: String?
    var id: String { recordId }
    func validate() throws {
        guard HouseholdValidation.identifier(recordId), (1...100_000).contains(ordinal),
              PersonalLearningContract.sources[sourceTable] == kind,
              (0...PersonalLearningContract.recordBytes).contains(payloadBytes) else { throw HouseholdFailure.invalid }
        if let recordedDate {
            guard ["journal_entries", "comfort_feedback"].contains(sourceTable), PersonalLearningContract.calendarDate(recordedDate) else { throw HouseholdFailure.invalid }
        }
    }
}
