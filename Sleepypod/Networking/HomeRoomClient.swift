import Foundation

protocol HomeRoomServing: Sendable {
    func status() async throws -> HomeRoomStatus
    func configure(_ config: HomeRoomConfiguration, expectedRevision: Int64) async throws -> HomeRoomVersion
    func history(before: Int64?) async throws -> HomeRoomHistory
    func publishers() async throws -> HomeRoomPublishers
}
struct CoreHomeRoomClient: HomeRoomServing {
    let transport: CoreRESTClient
    func status() async throws -> HomeRoomStatus {
        let result: HomeRoomStatus = try await transport.get("v1/home/context"); try result.validate(); return result
    }
    func configure(_ config: HomeRoomConfiguration, expectedRevision: Int64) async throws -> HomeRoomVersion {
        struct Request: Encodable, Sendable { let expectedRevision: Int64; let config: HomeRoomConfiguration }
        return try await transport.put("v1/home/context/configuration", body: Request(expectedRevision: expectedRevision, config: config.validated()), returning: HomeRoomVersion.self)
    }
    func history(before: Int64?) async throws -> HomeRoomHistory {
        let result: HomeRoomHistory = try await transport.get("v1/home/context/history", query: before.map { ["beforeId": String($0)] } ?? [:])
        try result.validate(before: before); return result
    }
    func publishers() async throws -> HomeRoomPublishers { try await transport.get("v1/home/context/publisher") }
}
struct DemoHomeRoomClient: HomeRoomServing {
    func status() -> HomeRoomStatus {
        .init(apiVersion: 1, generatedAt: Int64(Date.now.timeIntervalSince1970 * 1000), revision: 0, config: .empty, connected: false, topic: nil, observations: [])
    }
    func configure(_ config: HomeRoomConfiguration, expectedRevision: Int64) throws -> HomeRoomVersion {
        throw HomeRoomStatus.issue("Room sensor input is unavailable in Demo. Connect to your controller to save a mapping.")
    }
    func history(before: Int64?) -> HomeRoomHistory { .init(apiVersion: 1, generatedAt: Int64(Date.now.timeIntervalSince1970 * 1000), items: [], nextBeforeId: nil) }
    func publishers() throws -> HomeRoomPublishers { throw HomeRoomStatus.issue("Connect an MQTT broker on your controller before generating publishers.") }
}
