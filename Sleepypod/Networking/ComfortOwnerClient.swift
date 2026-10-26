import Foundation

protocol ComfortOwnerClient: Sendable {
    func status(side: Side) async throws -> ComfortOwnerStatus
    func prepare(_ input: ComfortOwnerPrepare) async throws -> ComfortOwnerReview
    func confirm(_ input: ComfortOwnerConfirm) async throws -> ComfortOwnerReceipt
    func retest(_ input: ComfortOwnerRetest) async throws -> ComfortOwnerReceipt
}

struct CoreComfortOwnerClient: ComfortOwnerClient {
    private struct Failure: Decodable { let message: String? }
    let transport: CoreRESTClient
    func status(side: Side) async throws -> ComfortOwnerStatus {
        try await send("v1/comfort/owner", method: "GET", query: ["side": side.rawValue])
    }
    func prepare(_ input: ComfortOwnerPrepare) async throws -> ComfortOwnerReview {
        guard (input.purpose == .qualification) == (input.kind != nil) else { throw ComfortOwnerValidation.invalid }
        return try await send("v1/comfort/owner/prepare", body: JSONEncoder().encode(input))
    }
    func confirm(_ input: ComfortOwnerConfirm) async throws -> ComfortOwnerReceipt {
        guard UUID(uuidString: input.id) != nil, input.confirmed, input.note.utf16.count <= 2000 else { throw ComfortOwnerValidation.invalid }
        return try await send("v1/comfort/owner/confirm", body: JSONEncoder().encode(input))
    }
    func retest(_ input: ComfortOwnerRetest) async throws -> ComfortOwnerReceipt {
        guard UUID(uuidString: input.expectedId) != nil else { throw ComfortOwnerValidation.invalid }
        return try await send("v1/comfort/owner/retest", body: JSONEncoder().encode(input))
    }
    private func send<Result: Decodable & Sendable>(_ path: String, method: String = "POST", query: [String: String] = [:], body: Data? = nil) async throws -> Result {
        var request = try transport.request(path, method: method, query: query, body: body)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await transport.session.data(for: request)
        guard data.count <= 1_048_576, let response = response as? HTTPURLResponse else { throw ComfortOwnerValidation.invalid }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONDecoder().decode(Failure.self, from: data))?.message
            throw APIError.serverError(message: response.statusCode == 401 ? "The controller rejected the connection key."
                : detail.map { String($0.prefix(400)) } ?? "Qualification request failed (HTTP \(response.statusCode)).")
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}
