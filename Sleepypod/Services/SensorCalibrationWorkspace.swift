import Foundation
import Observation

struct CalibrationTarget: Hashable, Sendable {
    let side: Side
    let kind: CalibrationKind
    var label: String { "\(side.displayName) \(kind.title)" }
}

@MainActor @Observable
final class SensorCalibrationWorkspace {
    private(set) var statuses: [Side: SensorCalibrationStatus] = [:]
    private(set) var errors: [Side: String] = [:]
    private(set) var receivedAt: [Side: Date] = [:]
    private(set) var loading = false
    private(set) var submitting = false
    private(set) var actionError: String?
    private(set) var notice: String?
    private(set) var completed = false
    private(set) var waiting: Set<CalibrationTarget> = []
    private var baseline: [CalibrationTarget: String] = [:]
    private var requestedAt: Date?
    private let client: any SensorCalibrationClient
    init(client: any SensorCalibrationClient) { self.client = client }
    var active: Bool { submitting || !waiting.isEmpty || statuses.values.contains(where: \.active) }
    var canTrigger: Bool { !loading && !active && errors.isEmpty && Side.allCases.allSatisfy { statuses[$0] != nil } }

    func refresh(now: Date = .now) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        for side in Side.allCases {
            do {
                let status = try await client.status(side)
                guard !Task.isCancelled else { return }
                statuses[side] = status; errors[side] = nil; receivedAt[side] = now
            } catch { if !Task.isCancelled { errors[side] = error.localizedDescription } }
        }
        reconcile(now: now)
    }

    // Capture existing identities before queuing. Trigger-all does not mark profiles pending in Core.
    func trigger(_ target: CalibrationTarget?, now: Date = .now) async {
        guard canTrigger else { return }
        let targets = target.map { [$0] } ?? Side.allCases.flatMap { side in CalibrationKind.allCases.map { CalibrationTarget(side: side, kind: $0) } }
        baseline = Dictionary(uniqueKeysWithValues: targets.compactMap { target in
            statuses[target.side]?[target.kind].map { (target, $0.identity) }
        })
        submitting = true; actionError = nil; notice = nil; completed = false
        defer { submitting = false }
        do {
            let result = try await client.trigger(target)
            guard result.triggered else { throw APIError.serverError(message: result.message) }
            waiting = Set(targets); requestedAt = now
            notice = "Queued. Waiting for new calibration results."
        } catch { actionError = error.localizedDescription; waiting = []; requestedAt = nil }
    }

    private func reconcile(now: Date) {
        guard !waiting.isEmpty else { return }
        var failures: [String] = []
        var finished: [CalibrationTarget] = []
        for target in waiting {
            guard errors[target.side] == nil, let profile = statuses[target.side]?[target.kind],
                  profile.created != nil, profile.identity != baseline[target] else { continue }
            if profile.status == "completed" { finished.append(target) }
            else if profile.status == "failed" {
                failures.append("\(target.label): \(profile.errorMessage ?? "Calibration failed")")
                finished.append(target)
            }
        }
        waiting.subtract(finished)
        if !failures.isEmpty {
            actionError = ([actionError].compactMap { $0 } + failures).joined(separator: "\n")
        }
        if waiting.isEmpty {
            completed = actionError == nil
            notice = completed ? "New calibration results received." : "Calibration finished with errors. Review the sensor results."
            requestedAt = nil
        } else if let requestedAt, now.timeIntervalSince(requestedAt) >= 120 {
            actionError = "No complete result was received within two minutes. The controller may still be processing. Refresh status before trying again."
            notice = nil; waiting = []; self.requestedAt = nil
        } else {
            notice = "Waiting for \(waiting.count) new \(waiting.count == 1 ? "sensor result" : "sensor results")."
        }
    }
}
