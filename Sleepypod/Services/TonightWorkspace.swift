import Foundation
import FreeSleepKit
import Observation

/// Read-only plan inventory expires independently and cannot survive a change of owner or side.
@MainActor @Observable final class TonightWorkspace {
    typealias ComfortReader = @MainActor (Side) async throws -> PersonalComfortStatus
    typealias AlarmReader = @MainActor (Side) async throws -> NextAlarmState
    typealias LimitReader = @MainActor (Side) async throws -> ComfortLimitPage
    private struct Receipt<Value> { let value: Value; let at: Date }
    private var comfort: Receipt<PersonalComfortStatus>?
    private var alarm: Receipt<NextAlarmState>?
    private var limit: Receipt<ComfortLimitPage>?
    private var owner: [String]?
    private var generation = 0
    private var side: Side = .left
    private var comfortReader: ComfortReader?
    private var alarmReader: AlarmReader?
    private var limitReader: LimitReader?
    private let currentOwner: () -> [String]?
    private(set) var busy = false

    init(currentOwner: @escaping () -> [String]? = { PersonalWorkspaceBoundary.isActive ? nil : OwnerConnection.revision }) {
        self.currentOwner = currentOwner
    }
    func configure(side: Side, comfort: ComfortReader?, alarm: AlarmReader?, limit: LimitReader?) {
        invalidate(); self.side = side; comfortReader = comfort; alarmReader = alarm; limitReader = limit; owner = currentOwner()
    }
    func invalidate() { generation += 1; owner = nil; comfort = nil; alarm = nil; limit = nil; busy = false }
    private func value<Value>(_ receipt: Receipt<Value>?, now: Date) -> Value? {
        guard let owner, owner == currentOwner(), let receipt, receipt.at <= now.addingTimeInterval(60), now.timeIntervalSince(receipt.at) <= 90 else { return nil }
        return receipt.value
    }
    func comfort(at now: Date) -> PersonalComfortStatus? { value(comfort, now: now) }
    func alarm(at now: Date) -> NextAlarmState? { value(alarm, now: now) }
    func limit(at now: Date) -> ComfortLimitPage? { value(limit, now: now) }
    func refresh() async {
        guard !busy, let owner, owner == currentOwner(), !Task.isCancelled else { return }
        let request = generation, target = side
        busy = true
        defer { if request == generation { busy = false } }
        do {
            guard let comfortReader else { throw APIError.noBaseURL }
            let response = try await comfortReader(target)
            try response.validate(side: target)
            guard current(request, owner) else { return }
            comfort = .init(value: response, at: .now)
        } catch { if current(request, owner) { comfort = nil } }
        guard current(request, owner) else { return }
        do {
            guard let alarmReader else { throw APIError.noBaseURL }
            let response = try await alarmReader(target)
            try response.validate(side: target)
            guard current(request, owner) else { return }
            alarm = .init(value: response, at: .now)
        } catch { if current(request, owner) { alarm = nil } }
        guard current(request, owner) else { return }
        do {
            guard let limitReader else { throw APIError.noBaseURL }
            let response = try await limitReader(target)
            try response.validate(for: target)
            guard current(request, owner) else { return }
            limit = .init(value: response, at: .now)
        } catch { if current(request, owner) { limit = nil } }
    }
    private func current(_ request: Int, _ expected: [String]) -> Bool {
        request == generation && expected == owner && expected == currentOwner() && !Task.isCancelled
    }
}
