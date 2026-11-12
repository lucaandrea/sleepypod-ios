#if DEBUG
import SwiftUI

/// Explicit simulator-only fixture. This transport never contacts a Pod.
struct ComfortExperimentPreview: View {
    @State private var model: ComfortExperimentWorkspace?
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            if let model { ComfortExperimentsScreen(model: model, synthetic: true) }
            else if let failure { ContentUnavailableView("Example unavailable", systemImage: "exclamationmark.triangle", description: Text(failure)) }
            else { ProgressView("Opening comparison example…") }
        }.task {
            do {
                let mode = UserDefaults.standard.string(forKey: "uiExperimentScenario") ?? "ready"
                let server = try ComfortExperimentPreviewServer(mode: mode)
                let start = Date()
                model = ComfortExperimentWorkspace(client: server, now: { server.baseDate.addingTimeInterval(Date().timeIntervalSince(start)) })
            } catch { failure = "The isolated comparison fixture could not be read." }
        }
    }
}

actor ComfortExperimentPreviewServer: ComfortExperimentTransport {
    nonisolated let baseDate: Date
    private let wallStart = Date()
    private let accessValue: ComfortExperimentAccess
    private let mode: String
    private let cases: [String: Data]
    private var record: [String: Any]
    private var execution: [String: Any]
    private var hasSaved: Bool
    private var lost = false
    init(mode: String) throws {
        self.mode = mode; hasSaved = mode != "empty"
        guard let url = Bundle.main.url(forResource: "comfort-experiments-v1", withExtension: "json"),
              let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let all = root["cases"] as? [String: [String: Any]], let values = all[mode.hasPrefix("owner") ? "legacy" : "personal"],
              let saved = values[mode == "unknown" || mode == "feedback" ? "running" : "saved"] as? [String: Any],
              let state = values[mode == "unknown" ? "uncertain" : "status"] as? [String: Any],
              let clock = values[mode == "feedback" ? "feedbackSaved" : mode == "unknown" ? "uncertain" : "status"] as? [String: Any],
              let generatedAt = clock["generatedAt"] as? NSNumber else { throw HouseholdFailure.invalid }
        cases = try values.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        let detail = try ComfortExperimentDecoding.decode(ComfortExperimentDetail.self, data: JSONSerialization.data(withJSONObject: saved))
        execution = state; record = saved
        baseDate = Date(timeIntervalSince1970: generatedAt.doubleValue / 1000)
        accessValue = .init(scope: detail.scope, revision: ["simulator-only"], execution: true)
    }
    private var timestamp: Int64 { Int64(baseDate.addingTimeInterval(Date().timeIntervalSince(wallStart)).timeIntervalSince1970 * 1000) }
    func access() async throws -> ComfortExperimentAccess { accessValue }
    func request(_ action: ComfortExperimentRequest) async throws -> Data {
        if mode == "loading" { try await Task.sleep(for: .seconds(60)) }
        if mode == "error" { throw HouseholdFailure.uncertain }
        let result: [String: Any]
        switch action {
        case .library: result = try library()
        case .detail: result = record
        case .execution: result = execution
        case .preview(let proposal):
            // The preview has one Core-generated plan. Unsupported edits are
            // rejected rather than silently returning a different proposal.
            var review = try object("review")
            let decoded = try ComfortExperimentDecoding.decode(ComfortExperimentReview.self, data: JSONSerialization.data(withJSONObject: review))
            guard decoded.plan.variantF == proposal.variantF, decoded.schedule.requestedFirstNightDate == proposal.firstNightDate else {
                throw ComfortExperimentFailure.reason("This practice example uses 69°F starting November 13. Your connected Pod reviews your actual choices.")
            }
            review["expiresAt"] = timestamp + 300_000; result = review
        case .save: hasSaved = true; result = record
        case .reviewControl:
            if mode == "unqualified" || mode == "ownerUnqualified" { throw ComfortExperimentFailure.reason("Finish the attended checks and review seven matching nights before allowing overnight comparisons.") }
            execution = try object("controlReview")
            var review = try nested(execution, "review")
            review["createdAt"] = timestamp; review["expiresAt"] = timestamp + 60_000; execution["review"] = review
            result = execution
        case .confirmControl:
            execution = try object("admitted"); result = execution
            if mode == "lost" && !lost { lost = true; throw HouseholdFailure.uncertain }
        case .stop:
            var saved = try nested(record, "record")
            saved["status"] = "stopped"; saved["revision"] = UUID().uuidString.lowercased()
            saved["updatedAt"] = timestamp; saved["stoppedAt"] = timestamp; record["record"] = saved
            execution["planStatus"] = "stopped"; result = record
            if mode == "partialStop" && !lost { lost = true; throw HouseholdFailure.uncertain }
        case .cancelControl:
            var admission = try nested(execution, "admission")
            admission["revokedAt"] = timestamp; admission["reason"] = "Cancelled by the sleeper"
            execution["admission"] = admission; execution["state"] = "revoked"; result = execution
        case .recover:
            execution = try object("recovered"); result = execution
        case .feedback(_, _, let value):
            try saveFeedback(value); result = record
        }
        var value = result; value["generatedAt"] = timestamp
        return try JSONSerialization.data(withJSONObject: value)
    }
    private func library() throws -> [String: Any] {
        var value = try object(hasSaved ? "savedLibrary" : "library")
        if hasSaved {
            let saved = try nested(record, "record")
            guard var items = value["experiments"] as? [[String: Any]], !items.isEmpty else { throw HouseholdFailure.invalid }
            for key in ["status", "revision", "updatedAt"] { items[0][key] = saved[key] }
            value["experiments"] = items
        }
        return value
    }
    private func saveFeedback(_ value: ComfortExperimentFeedback) throws {
        try value.validate()
        var saved = try nested(record, "record")
        guard var feedback = saved["feedback"] as? [[String: Any]],
              var entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else { throw HouseholdFailure.invalid }
        entry["recordedAt"] = timestamp
        feedback.removeAll { $0["nightDate"] as? String == value.nightDate }; feedback.append(entry)
        saved["feedback"] = feedback; saved["updatedAt"] = timestamp; saved["revision"] = UUID().uuidString.lowercased(); record["record"] = saved
        // No physical exposure is invented by recording a comfort rating.
    }
    private func object(_ key: String) throws -> [String: Any] {
        guard let data = cases[key], let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HouseholdFailure.invalid }
        return value
    }
    private func nested(_ value: [String: Any], _ key: String) throws -> [String: Any] {
        guard let result = value[key] as? [String: Any] else { throw HouseholdFailure.invalid }
        return result
    }
}
#endif
