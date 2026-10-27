import Foundation

protocol BedroomServing: Sendable {
    func status() async throws -> BedroomStatus
    func configure(_ config: BedroomConfiguration, expectedRevision: Int64) async throws -> BedroomVersion
}

struct CoreBedroomClient: BedroomServing {
    let transport: CoreRESTClient
    func status() async throws -> BedroomStatus {
        let result: BedroomStatus = try await transport.get("v1/home/bedroom")
        try result.validate()
        return result
    }
    func configure(_ config: BedroomConfiguration, expectedRevision: Int64) async throws -> BedroomVersion {
        struct Request: Encodable, Sendable { let expectedRevision: Int64; let config: BedroomConfiguration }
        try config.validate()
        return try await transport.put("v1/home/bedroom/configuration", body: Request(expectedRevision: expectedRevision, config: config), returning: BedroomVersion.self)
    }
}

struct DemoBedroomClient: BedroomServing {
    func status() -> BedroomStatus {
        .init(apiVersion: 1, generatedAt: Int64(Date.now.timeIntervalSince1970 * 1000), revision: 0, config: .empty, observations: [], aggregates: [], guidance: .unavailable, mqtt: nil)
    }
    func configure(_ config: BedroomConfiguration, expectedRevision: Int64) throws -> BedroomVersion {
        throw APIError.serverError(message: "Connect to your controller to configure bedroom devices.")
    }
}
