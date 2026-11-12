import Foundation
import Observation

/// Ephemeral bed controls. Only a reachable, activated session can deliver a new tap; nothing is queued.
@MainActor @Observable final class BedRemoteClient {
    private(set) var snapshot: BedRemoteSnapshot?
    private(set) var message = "Refresh to connect through your iPhone."
    private(set) var refreshing = false
    private(set) var adjusting = false
    private(set) var stopping = false
    let isExample: Bool
    private var generation = 0
    private let send: @MainActor (Data) async throws -> Data
    private let reachable: @MainActor () -> Bool
    private let now: @MainActor () -> Date

    init(isExample: Bool = false, send: @escaping @MainActor (Data) async throws -> Data,
         reachable: @escaping @MainActor () -> Bool, now: @escaping @MainActor () -> Date = Date.init) {
        self.isExample = isExample; self.send = send; self.reachable = reachable; self.now = now
    }
    func invalidate() { generation += 1; snapshot = nil; message = "Refresh to check your current account and bed side." }
    func canAdjust(at now: Date) -> Bool {
        reachable() && !adjusting && !refreshing && !stopping && snapshot.map { $0.isCurrent(at: now) && $0.readingsFresh(at: now) && $0.canAdjust } == true
    }
    func canStop(at now: Date) -> Bool {
        reachable() && !stopping && snapshot.map { $0.isCurrent(at: now) && $0.canStop } == true
    }
    func refresh() async {
        guard !refreshing, !adjusting, !stopping else { return }
        refreshing = true; defer { refreshing = false }
        snapshot = nil
        await perform(.init(action: .refresh, now: now()))
    }
    func setTemperature(_ target: Int) async {
        guard canAdjust(at: now()), let snapshot else { return }
        adjusting = true; defer { adjusting = false }
        await perform(.init(action: .temperature, lease: snapshot.lease, temperatureF: target, now: now()))
    }
    func stop(vibration: Bool) async {
        guard canStop(at: now()), let snapshot else { return }
        stopping = true; generation += 1; defer { stopping = false }
        await perform(.init(action: vibration ? .stopVibration : .stopTemperature, lease: snapshot.lease, now: now()))
    }
    private func perform(_ request: BedRemoteRequest) async {
        guard reachable() else { snapshot = nil; message = "iPhone is unreachable. Keep it nearby with Bluetooth and Wi-Fi on, then refresh."; return }
        let operation = generation
        do {
            let data = try await send(JSONEncoder().encode(request))
            guard operation == generation, data.count <= 16_384 else { throw BedRemoteFailure.changed }
            let reply = try JSONDecoder().decode(BedRemoteReply.self, from: data)
            guard reply.requestID == request.id, reply.message.count <= 500 else { throw BedRemoteFailure.invalid }
            if request.action == .refresh, reply.outcome == .snapshot, let snapshot = reply.snapshot {
                try snapshot.validate()
                guard snapshot.isCurrent(at: now()) else { throw BedRemoteFailure.expired }
                self.snapshot = snapshot
            } else { snapshot = nil }
            message = reply.message
        } catch {
            guard operation == generation else { return }
            snapshot = nil
            message = request.action == .refresh ? "Could not refresh. Open sleepypod on iPhone and check its Pod connection."
                : "Result unconfirmed. Check command history on iPhone. This tap has not been repeated."
        }
    }
}
