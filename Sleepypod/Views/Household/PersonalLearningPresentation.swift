import Foundation

enum PersonalLearningPresentation {
    static let titles: [String: String] = [
        "comfort_states": "Comfort settings", "comfort_feedback": "Comfort check-in", "journal_entries": "Journal entry",
        "comfort_moments": "Comfort moment", "comfort_models": "Temperature learning model", "comfort_reviews": "Learning review",
        "comfort_events": "Automatic adjustment history", "thermal_forecasts": "Water-temperature forecast",
        "target_response_models": "Bed response model", "side_stage_models": "Sleep-stage model", "stage_model_library": "Saved sleep-stage model",
        "stage_classifier_changes": "Sleep-stage settings change", "biometric_profile_revisions": "Sensor processing profile",
        "biometric_profile_bindings": "Sensor profile assignment"
    ]
    struct Reading { let title: String; let note: String?; let facts: [(String, String)] }
    static func date(_ value: Int64) -> String { Date(timeIntervalSince1970: Double(value) / 1_000).formatted(date: .abbreviated, time: .shortened) }
    static func day(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return value }
        formatter.locale = .current; formatter.dateStyle = .medium; formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    static func title(_ record: PersonalLearningRecord) -> String {
        "\(titles[record.sourceTable] ?? "Saved record") · \(record.recordedDate.map(day) ?? "record \(record.ordinal)")"
    }
    /// Interpret only validated, known personal fields; a model stays an original historical file.
    static func reading(_ detail: PersonalLearningDetail) -> Reading {
        let fallback = Reading(title: titles[detail.sourceTable] ?? "Saved record", note: nil, facts: [])
        guard let payload = detail.payload else { return fallback }
        struct Row: Decodable { let side: Side; let local_date: String; let record: String?; let comfort: String? }
        do {
            let row = try JSONDecoder().decode(Row.self, from: Data(payload.utf8))
            guard row.side == detail.sourceSide, PersonalLearningContract.calendarDate(row.local_date) else { return fallback }
            if detail.sourceTable == "journal_entries", let encoded = row.record {
                let record = try JSONDecoder().decode(MorningJournalRecord.self, from: Data(encoded.utf8))
                try record.validate()
                guard record.side == row.side, record.date == row.local_date else { return fallback }
                return Reading(title: "Journal · \(day(record.date))", note: record.fields.notes.isEmpty ? nil : record.fields.notes,
                               facts: [("Comfort", comfort(record.fields.comfort)), ("Restfulness", "\(record.fields.restfulness) of 5")])
            }
            if detail.sourceTable == "comfort_feedback", let value = row.comfort, ["warm", "cold", "comfortable"].contains(value) {
                return Reading(title: "Comfort · \(day(row.local_date))", note: nil, facts: [("Your check-in", comfort(value))])
            }
        } catch { return fallback }
        return fallback
    }
    private static func comfort(_ value: String) -> String { value == "warm" ? "Felt warm" : value == "cold" ? "Felt cold" : "Comfortable" }
}
