import Foundation

protocol MorningJournalClient: Sendable {
    func available() async throws
    func read(side: Side, date: String?, days: Int) async throws -> MorningJournalPage
    func write(_ input: MorningJournalWrite) async throws -> MorningJournalSelection
}

struct CoreMorningJournalClient: MorningJournalClient {
    private struct Capabilities: Decodable, Sendable {
        struct Features: Decodable, Sendable {
            struct Feature: Decodable, Sendable { let implemented: Bool; let runtime: String }
            let morningJournal: Feature?
        }
        struct Endpoints: Decodable, Sendable { let journal: String? }
        let apiVersion: Int
        let features: Features
        let endpoints: Endpoints
    }
    let transport: CoreRESTClient
    func available() async throws {
        let result: Capabilities = try await send("v1/capabilities", method: "GET")
        guard result.apiVersion == 1, result.features.morningJournal?.implemented == true,
              result.features.morningJournal?.runtime == "ready", result.endpoints.journal == "/api/v1/journal" else {
            throw MorningJournalFailure.unavailable("This controller does not yet support the morning journal. Update it before editing check-ins.")
        }
    }
    func read(side: Side, date: String?, days: Int) async throws -> MorningJournalPage {
        guard (1...90).contains(days), date.map(MorningJournalDates.valid) ?? true else { throw MorningJournalFailure.invalid }
        var query = ["side": side.rawValue, "days": String(days)]; query["date"] = date
        return try await send("v1/journal", method: "GET", query: query)
    }
    func write(_ input: MorningJournalWrite) async throws -> MorningJournalSelection {
        try input.fields?.validate()
        guard MorningJournalDates.valid(input.date), input.expectedRevision.map({ UUID(uuidString: $0) != nil }) ?? true else { throw MorningJournalFailure.invalid }
        return try await send("v1/journal", method: "POST", body: JSONEncoder().encode(input))
    }
    /// Keep journal data out of caches and error logs; status 409 retains the caller's draft.
    private func send<Result: Decodable & Sendable>(_ path: String, method: String, query: [String: String] = [:], body: Data? = nil) async throws -> Result {
        var request = try transport.request(path, method: method, query: query, body: body)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await transport.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MorningJournalFailure.invalid }
        if response.statusCode == 409 { throw MorningJournalFailure.conflict }
        guard (200..<300).contains(response.statusCode) else {
            throw MorningJournalFailure.unavailable(response.statusCode == 401 ? "The controller rejected the connection key."
                : "The journal could not be read or saved (HTTP \(response.statusCode)). Your draft has not been discarded.")
        }
        guard data.count <= 1_048_576 else { throw MorningJournalFailure.invalid }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}
