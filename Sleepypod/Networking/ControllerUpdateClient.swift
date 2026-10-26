import Foundation

protocol ControllerUpdateServing: Sendable {
    var scope: String { get }
    func snapshot() async throws -> ControllerUpdateSnapshot
    func version() async throws -> ControllerBuild
    func internetBlocked() async throws -> Bool
    func trigger(channel: ControllerUpdateChannel) async throws -> ControllerUpdateReceipt
    func blockInternet() async throws -> Bool
}
struct CoreControllerUpdateClient: ControllerUpdateServing {
    let transport: CoreRESTClient
    var scope: String { transport.endpoint.absoluteString }
    func snapshot() async throws -> ControllerUpdateSnapshot {
        async let build = version()
        async let blocked = internetBlocked()
        let schema: CoreAPIDocument = try await transport.get("openapi.json")
        let pinned = schema.returns("repository", path: "/system/update", method: "post")
        return try await .init(build: build, internetBlocked: blocked, preservesInstalledRepository: pinned)
    }
    func version() async throws -> ControllerBuild { try await transport.get("system/version") }
    func internetBlocked() async throws -> Bool {
        let response: InternetState = try await transport.get("system/internet-status")
        return response.blocked
    }
    func trigger(channel: ControllerUpdateChannel) async throws -> ControllerUpdateReceipt {
        try await transport.post("system/update", body: ["branch": channel.rawValue], returning: ControllerUpdateReceipt.self)
    }
    func blockInternet() async throws -> Bool {
        let response: InternetState = try await transport.post("system/internet-access", body: ["blocked": true], returning: InternetState.self)
        return response.blocked
    }
    private struct InternetState: Decodable, Sendable { let blocked: Bool }
}

/// The demo only changes this in-memory fixture; it never runs an updater or changes networking.
actor DemoControllerUpdateClient: ControllerUpdateServing {
    nonisolated let scope = "demo-controller-update"
    private var updated = false
    private var channel: ControllerUpdateChannel = .main
    private var blocked = true
    private var pendingRead = false
    func version() throws -> ControllerBuild {
        if pendingRead { pendingRead = false; throw APIError.serverError(message: "Simulated reconnection") }
        return .init(branch: channel.rawValue, commitHash: updated ? "synthetic-new-build" : "synthetic-installed-build",
                     commitTitle: "Synthetic build for interface demonstration", buildDate: updated ? "2026-10-26T01:00:00Z" : "2026-10-25T01:00:00Z", version: nil)
    }
    func snapshot() throws -> ControllerUpdateSnapshot {
        try .init(build: version(), internetBlocked: blocked, preservesInstalledRepository: true)
    }
    func internetBlocked() -> Bool { blocked }
    func trigger(channel: ControllerUpdateChannel) -> ControllerUpdateReceipt {
        self.channel = channel; updated = true; pendingRead = true
        return .init(triggered: true, branch: channel.rawValue, repository: "synthetic/demo", message: "Simulated request; no update was run.")
    }
    func blockInternet() -> Bool { blocked = true; return blocked }
}
