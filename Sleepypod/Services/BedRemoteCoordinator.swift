import Foundation

/// Private context never crosses to the Watch; only an expiring random lease does.
struct BedRemoteReading {
    let context: [String]
    let snapshot: BedRemoteSnapshot
}

@MainActor protocol BedRemoteSource: AnyObject {
    var context: [String] { get }
    func prepareRead() throws
    func read() async throws -> BedRemoteReading
    func perform(_ request: BedRemoteRequest, reviewed: BedRemoteReading,
                 validateBeforeSubmit: @escaping @MainActor () throws -> Void) async throws -> String
}

extension BedRemoteSource {
    func prepareRead() throws {}
}

/// Claims each tap before suspension. Disconnects, duplicates and re-launches never replay an actuator request.
@MainActor final class BedRemoteCoordinator {
    private let source: any BedRemoteSource
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private var receivedUptime: TimeInterval?
    private var reading: BedRemoteReading?
    private struct Claim { let request: BedRemoteRequest; let context: [String]; var reply: BedRemoteReply }
    private var claims: [UUID: Claim] = [:]
    private var order: [UUID] = []
    private var pending: Set<UUID> = []
    private var stopEpoch = 0
    private var refreshGeneration = 0

    init(source: any BedRemoteSource, now: @escaping () -> Date = Date.init, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.source = source; self.now = now; self.uptime = uptime
    }
    func invalidate() { reading = nil; stopEpoch += 1; refreshGeneration += 1 }

    func handle(_ request: BedRemoteRequest) async -> BedRemoteReply {
        do { try request.validate(at: now()) }
        catch { return reply(request, .withheld, error.localizedDescription) }
        if let claim = claims[request.id] {
            guard claim.request == request, claim.context == source.context else { return reply(request, .withheld, BedRemoteFailure.changed.localizedDescription) }
            return claim.reply
        }
        if request.action == .refresh { return await refresh(request) }
        guard request.isStopping || pending.isEmpty else { return reply(request, .withheld, BedRemoteFailure.busy.localizedDescription) }
        guard let reviewed = reading else { return reply(request, .withheld, BedRemoteFailure.changed.localizedDescription) }
        do { try validate(request, reviewed: reviewed) }
        catch { return reply(request, .withheld, error.localizedDescription) }
        if request.isStopping { stopEpoch += 1 }
        let epoch = stopEpoch
        let uncertain = reply(request, .uncertain, "Awaiting the controller. This tap will not be sent again.")
        claims[request.id] = Claim(request: request, context: reviewed.context, reply: uncertain); order.append(request.id); pending.insert(request.id)
        defer {
            pending.remove(request.id)
            if reading?.snapshot.lease == reviewed.snapshot.lease { reading = nil }
            prune()
        }
        do {
            let message = try await source.perform(request, reviewed: reviewed, validateBeforeSubmit: { [weak self] in
                guard let self else { throw BedRemoteFailure.unavailable }
                try self.validate(request, reviewed: reviewed)
                guard request.isStopping || self.stopEpoch == epoch else { throw BedRemoteFailure.changed }
            })
            guard source.context == reviewed.context else { throw BedRemoteFailure.changed }
            let result = reply(request, .acknowledged, message)
            claims[request.id]?.reply = result; return result
        } catch {
            // A thrown transport error may follow a successful hardware write. Never label it unsent.
            let result = reply(request, .uncertain, error.localizedDescription)
            claims[request.id]?.reply = result; return result
        }
    }
    private func refresh(_ request: BedRemoteRequest) async -> BedRemoteReply {
        refreshGeneration += 1; let generation = refreshGeneration
        reading = nil
        do {
            try source.prepareRead()
            let context = source.context
            let result = try await source.read()
            try request.validate(at: now()); try result.snapshot.validate()
            guard generation == refreshGeneration, result.context == context, source.context == context,
                  result.snapshot.isCurrent(at: now()) else { throw BedRemoteFailure.changed }
            reading = result; receivedUptime = uptime()
            return .init(requestID: request.id, outcome: .snapshot, snapshot: result.snapshot, message: "Bed refreshed")
        } catch { return reply(request, .withheld, error.localizedDescription) }
    }
    private func validate(_ request: BedRemoteRequest, reviewed: BedRemoteReading) throws {
        try Task.checkCancellation(); try request.validate(at: now())
        guard reviewed.context == source.context, reading?.snapshot.lease == reviewed.snapshot.lease,
              request.lease == reviewed.snapshot.lease, reviewed.snapshot.isCurrent(at: now()),
              let receivedUptime, uptime() >= receivedUptime, uptime() - receivedUptime < 30 else { throw BedRemoteFailure.changed }
        guard request.isStopping ? reviewed.snapshot.canStop
                : reviewed.snapshot.canAdjust && reviewed.snapshot.readingsFresh(at: now()) else { throw BedRemoteFailure.unavailable }
    }
    private func reply(_ request: BedRemoteRequest, _ outcome: BedRemoteReply.Outcome, _ message: String) -> BedRemoteReply {
        .init(requestID: request.id, outcome: outcome, snapshot: nil, message: String(message.prefix(500)))
    }
    private func prune() {
        while order.count > 64, let oldest = order.first, !pending.contains(oldest) {
            claims[oldest] = nil; order.removeFirst()
        }
    }
}
