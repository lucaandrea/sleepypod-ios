import Foundation
import WatchConnectivity

/// WatchConnectivity transport for the shared, testable live-control state machine.
extension BedRemoteClient {
    static func configured() -> BedRemoteClient {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--bed-remote-example") {
            let index = arguments.firstIndex(of: "--example-state")
            let state = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "ready"
            let example = WatchBedExample(state: state)
            return .init(isExample: true, send: { try await example.send($0) }, reachable: { true })
        }
        #endif
        return .init(send: sendLive, reachable: { WCSession.default.activationState == .activated && WCSession.default.isReachable })
    }
    private static func sendLive(_ data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let reply = WatchLiveReply(continuation)
            WCSession.default.sendMessageData(data, replyHandler: { reply.finish(.success($0)) },
                errorHandler: { reply.finish(.failure($0)) })
            Task {
                try? await Task.sleep(for: .seconds(20))
                reply.finish(.failure(URLError(.timedOut)))
            }
        }
    }
}

/// A late system reply after our display timeout must not resume the same continuation twice.
private final class WatchLiveReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Data, Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with: result)
    }
}
