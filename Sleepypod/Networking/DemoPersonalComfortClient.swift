import Foundation

struct PersonalComfortExample: Decodable, Sendable {
    let status: PersonalComfortStatus
    let report: ComfortNightDetail
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "personal-comfort-example", withExtension: "json") else { throw APIError.serverError(message: "The personal-comfort example is unavailable.") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
/// Demo records only local choices. The optional sample report can never qualify a night.
actor DemoPersonalComfortClient: PersonalComfortClient {
    let includeExample: Bool
    private var configurations: [Side: PersonalComfortConfig] = [:]
    private var reviews: [Side: ComfortNightReview] = [:]
    private var feedbacks: [Side: PersonalComfortFeedback] = [:]
    private var history: [Side: [PersonalComfortEvent]] = [:]
    init(includeExample: Bool = false) { self.includeExample = includeExample }
    func status(side: Side) throws -> PersonalComfortStatus {
        let source = try PersonalComfortExample.load().status, original = source.state!
        var features = source.features; features.ownerActivation = true
        let config = configurations[side] ?? original.config
        let signals: PersonalComfortSignals? = config.sensorAware == true
            ? .init(state: "stale", reason: "Demo has no qualified live Pod estimates.", sampleAt: nil, expiresAt: nil, baselineHeartRate: nil, baselineDays: 0, baselineWindows: 0, baselineAsOf: nil, recentHeartRates: [], sourceSide: nil, source: "qualified_live_pod") : nil
        let timing: PersonalComfortTiming? = config.followBedtime == true
            ? .init(state: "waiting", reason: "Demo cannot observe bed entry. Actual entry requires ten minutes of fresh calibrated presence.", selection: nil, scheduledBaselineF: nil, phaseBaselineF: nil) : nil
        return .init(apiVersion: 1, generatedAt: source.generatedAt, side: side, timezone: source.timezone, deviceDate: source.deviceDate,
                     state: .init(config: config, offsetF: 0, feedbackThrough: feedbacks[side]?.date ?? "", learnedSession: "", pausedUntil: 0, lastAppliedAt: 0, lastTargetF: nil, lastSegment: ""),
                     evaluatedAt: nil, decision: nil, fault: nil, history: history[side] ?? [], runtime: "stopped", activation: source.activation, features: features, signals: signals, timing: timing)
    }
    func configure(side: Side, config: PersonalComfortConfig) throws -> PersonalComfortStatus { try config.validate(); configurations[side] = config; return try status(side: side) }
    func mode(side: Side, mode: String) async throws -> PersonalComfortStatus {
        guard ["off", "preview"].contains(mode) else { throw APIError.serverError(message: "Active comfort adjustments are not available.") }
        var config = try status(side: side).state!.config; config.mode = mode
        configurations[side] = config; return try status(side: side)
    }
    func feedback(side: Side, input: PersonalComfortFeedback) throws -> PersonalComfortStatus {
        let current = try status(side: side); try input.validate(deviceDate: current.deviceDate)
        feedbacks[side] = input
        let label = input.comfort == "warm" ? "too warm" : input.comfort == "cold" ? "too cold" : "comfortable"
        let event = PersonalComfortEvent(at: current.generatedAt, kind: "feedback", session: nil, message: "Demo check-in for \(input.date): \(label).",
                                         proposedF: nil, reportedF: nil, eligible: false, deviceObservedAt: nil, presenceObservedAt: nil, owner: nil, signals: nil, timing: nil)
        history[side] = Array(([event] + (history[side] ?? [])).prefix(20))
        return try status(side: side)
    }
    func reports(side: Side) throws -> ComfortNightList {
        let fixture = try PersonalComfortExample.load()
        let items = includeExample ? [try report(side: side, id: fixture.report.summary.id, after: nil).item] : []
        return .init(apiVersion: 1, generatedAt: fixture.status.generatedAt, side: side, items: items, targetNights: 7, ownerConfirmedNights: 0, activationAvailable: false)
    }
    func report(side: Side, id: String, after: Int?) throws -> ComfortNightDetail {
        let source = try PersonalComfortExample.load().report
        guard includeExample, id == source.summary.id else { throw APIError.serverError(message: "There is no actual overnight report in Demo.") }
        let records = source.observations.filter { $0.id > (after ?? 0) }, page = Array(records.prefix(2))
        return .init(summary: source.summary, review: reviews[side], reviewCurrent: reviews[side] != nil, countsAsOwnerConfirmedNight: false,
                     observations: page, nextAfterId: records.count > page.count ? page.last?.id : nil)
    }
    func review(_ input: ComfortReviewInput) throws -> ComfortNightReview {
        let current = try report(side: input.side, id: input.id, after: nil); try input.validate(report: current)
        guard input.outcome == "needs_retest", !input.confirmedActualNight else { throw APIError.serverError(message: "A simulated example cannot be confirmed as an actual night.") }
        let result = ComfortNightReview(id: (reviews[input.side]?.id ?? 0) + 1, at: Date.now.timeIntervalSince1970 * 1000, digest: input.digest,
                                       outcome: input.outcome, confirmedActualNight: false, note: input.note.trimmingCharacters(in: .whitespacesAndNewlines))
        reviews[input.side] = result; return result
    }
}
