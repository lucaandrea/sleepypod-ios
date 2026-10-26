import Foundation

/// The framework exposes intent values; native services own Core contracts and Health writes.
public enum NativePodAction: Sendable, Equatable {
    case temperature(side: String, value: Double)
    case readTemperature(side: String, current: Bool)
    case power(side: String, enabled: Bool)
    case position(head: Int, feet: Int)
    case preset(String)
    case stopBase
    case dismissAlarm(side: String)
    case away(side: String, enabled: Bool)
    case prime
    case comfort(side: String, mode: String)
    case nextAlarm(side: String)
    case changeAlarm(side: String, action: String, time: String?)
    case summary(side: String)
    case syncHealth
}

public enum NativePodActionReply: Sendable, Equatable {
    case message(String)
    case number(Double)
    case healthSamples(Int)
}

public struct NativePodActionBridge: Sendable {
    private let handler: @MainActor @Sendable (NativePodAction) async throws -> NativePodActionReply
    public init(handler: @escaping @MainActor @Sendable (NativePodAction) async throws -> NativePodActionReply) { self.handler = handler }
    public static let unavailable = Self { _ in throw PodError.message("Open sleepypod once to initialize your native actions, then try again.") }
    public func perform(_ action: NativePodAction) async throws -> NativePodActionReply {
        try AppMode.requireLiveConnection()
        try Task.checkCancellation()
        return try await handler(action)
    }
    public func message(_ action: NativePodAction) async throws -> String {
        guard case .message(let message) = try await perform(action) else { throw PodError.message("The action returned an unexpected result.") }
        return message
    }
    public func number(_ action: NativePodAction) async throws -> Double {
        guard case .number(let value) = try await perform(action), value.isFinite else { throw PodError.message("The requested measurement is unavailable.") }
        return value
    }
    public func syncHealth() async throws -> Int {
        guard case .healthSamples(let count) = try await perform(.syncHealth), count >= 0 else { throw PodError.message("The Health sync could not be confirmed.") }
        return count
    }
}
