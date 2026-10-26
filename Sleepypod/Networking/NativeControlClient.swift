import Foundation

protocol NativeControlClient: Sendable {
    func available() async throws
    func submit(_ request: NativeControlRequest) async throws -> NativeControlReceipt
    func read(_ request: NativeControlRequest) async throws -> NativeControlReceipt
}

struct CoreNativeControlClient: NativeControlClient {
    private struct Capabilities: Decodable, Sendable {
        struct Endpoints: Decodable, Sendable { let controls: String? }
        struct Semantics: Decodable, Sendable {
            let durableCommandReceipts: Bool
            let commandExpiry: Bool
            let receiptScope: String
            let maxLifetimeMs: Int
        }
        let apiVersion: Int
        let endpoints: Endpoints
        let controlSemantics: Semantics
    }
    let transport: CoreRESTClient
    func available() async throws {
        let value: Capabilities = try await send("v1/capabilities", method: "GET")
        guard value.apiVersion == 1, value.endpoints.controls == "/api/v1/controls",
              value.controlSemantics.durableCommandReceipts, value.controlSemantics.commandExpiry,
              value.controlSemantics.receiptScope == "versioned_controls_only", value.controlSemantics.maxLifetimeMs == 60_000 else { throw NativeControlFailure.unavailable }
    }
    func submit(_ request: NativeControlRequest) async throws -> NativeControlReceipt {
        try request.validate()
        let receipt: NativeControlReceipt = try await send("v1/controls", method: "POST", body: JSONEncoder().encode(request))
        try receipt.validate(for: request); return receipt
    }
    func read(_ request: NativeControlRequest) async throws -> NativeControlReceipt {
        let receipt: NativeControlReceipt = try await send("v1/controls/\(request.requestId.uuidString.lowercased())", method: "GET")
        try receipt.validate(for: request); return receipt
    }
    private func send<Result: Decodable & Sendable>(_ path: String, method: String, body: Data? = nil) async throws -> Result {
        var request = try transport.request(path, method: method, body: body)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await transport.session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 65_536 else { throw NativeControlFailure.invalid }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.serverError(message: response.statusCode == 401 ? "The controller rejected the connection key."
                : "Command receipt unavailable (HTTP \(response.statusCode)). The command will not be resent.")
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}
