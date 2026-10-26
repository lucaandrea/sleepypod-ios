import Foundation

protocol ImportedHistoryClient: Sendable {
    func status() async throws -> ImportedHistoryStatus
    func page(_ query: ImportedHistoryQuery) async throws -> ImportedHistoryPage
    func presence(snapshotID: String, record: ImportedPresenceRecord) async throws -> ImportedHistoryDetail
}

struct CoreImportedHistoryClient: ImportedHistoryClient {
    private struct Failure: Decodable { let message: String? }
    let transport: CoreRESTClient
    func status() async throws -> ImportedHistoryStatus { try await read("v1/history") }
    func page(_ query: ImportedHistoryQuery) async throws -> ImportedHistoryPage {
        try query.validate()
        return try await read("v1/history/records", query: query.parameters)
    }
    func presence(snapshotID: String, record: ImportedPresenceRecord) async throws -> ImportedHistoryDetail {
        try ImportedHistoryValidation.digest(snapshotID); try ImportedHistoryRecord.presence(record).validate()
        return try await read("v1/history/presence", query: ["snapshotId": snapshotID, "side": record.side.rawValue, "id": String(record.id)])
    }
    /// Preserve the snapshot-conflict status so paging cannot mix two imported archives.
    private func read<Result: Decodable & Sendable>(_ path: String, query: [String: String] = [:]) async throws -> Result {
        var request = try transport.request(path, method: "GET", query: query)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await transport.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse(statusCode: 0) }
        if response.statusCode == 409 { throw ImportedHistoryFailure.changed }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.message
            throw ImportedHistoryFailure.unavailable(response.statusCode == 401 ? "The controller rejected the connection key."
                : message.map { String($0.prefix(400)) } ?? "Imported history could not be read (HTTP \(response.statusCode)).")
        }
        guard data.count <= 8_388_608 else { throw ImportedHistoryFailure.invalid("The archive response is too large. Choose a smaller range.") }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}

struct ImportedHistoryExample: Decodable, Sendable {
    struct Pages: Decodable, Sendable {
        let presence: ImportedHistoryPage
        let presenceNext: ImportedHistoryPage
        let vitals: ImportedHistoryPage
        let movement: ImportedHistoryPage
    }
    let synthetic: Bool
    let status: ImportedHistoryStatus
    let notImported: ImportedHistoryStatus
    let pages: Pages
    let detail: ImportedHistoryDetail
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "imported-history-example", withExtension: "json") else {
            throw ImportedHistoryFailure.unavailable("The synthetic history example is unavailable.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

struct DemoImportedHistoryClient: ImportedHistoryClient {
    var scenario = "empty"
    func status() throws -> ImportedHistoryStatus {
        if scenario == "offline" { throw URLError(.notConnectedToInternet) }
        let example = try ImportedHistoryExample.load()
        return scenario == "empty" ? example.notImported : example.status
    }
    func page(_ query: ImportedHistoryQuery) throws -> ImportedHistoryPage {
        if scenario == "changed" { throw ImportedHistoryFailure.changed }
        let example = try ImportedHistoryExample.load()
        let source: ImportedHistoryPage
        switch query.kind {
        case .presence: source = query.cursor == nil ? example.pages.presence : example.pages.presenceNext
        case .vitals: source = example.pages.vitals
        case .movement: source = example.pages.movement
        }
        let records = source.records.filter { record in
            guard record.side == query.side else { return false }
            if case .presence(let value) = record { return value.leftBedAt > query.start.timeIntervalSince1970 && value.enteredBedAt < query.end.timeIntervalSince1970 }
            return record.timestamp >= query.start.timeIntervalSince1970 && record.timestamp < query.end.timeIntervalSince1970
        }
        return .init(apiVersion: 1, snapshotId: query.snapshotID, side: query.side, kind: query.kind, records: records,
                     nextCursor: records.isEmpty ? nil : source.nextCursor, semantics: source.semantics)
    }
    func presence(snapshotID: String, record: ImportedPresenceRecord) throws -> ImportedHistoryDetail {
        let source = try ImportedHistoryExample.load().detail
        if source.record == record { return source }
        return .init(apiVersion: 1, snapshotId: snapshotID, record: record,
                     present: .init(status: .unavailable, intervals: nil, coveredSeconds: nil),
                     absent: .init(status: .unavailable, intervals: nil, coveredSeconds: nil),
                     rawPresentIntervals: nil, rawAbsentIntervals: nil, semantics: source.semantics)
    }
}
