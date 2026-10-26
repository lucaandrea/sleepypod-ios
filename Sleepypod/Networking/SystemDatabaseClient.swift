import Foundation

protocol SystemDatabaseClient: Sendable {
    func overview(fresh: Bool) async throws -> SystemDatabaseOverview
    func rows(_ query: SystemDatabaseQuery) async throws -> SystemDatabaseRows
    func integrity() async throws -> [String: SystemDatabase.IntegrityRun]
    func backup(directory: URL) async throws -> URL
}

struct CoreSystemDatabaseClient: SystemDatabaseClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func overview(fresh: Bool) async throws -> SystemDatabaseOverview { try await client.get("system/databases", query: ["fresh": String(fresh)]) }
    func rows(_ query: SystemDatabaseQuery) async throws -> SystemDatabaseRows {
        if let message = query.validation { throw APIError.serverError(message: message) }
        return try await client.get("system/databases/rows", query: query.parameters)
    }
    func integrity() async throws -> [String: SystemDatabase.IntegrityRun] {
        struct Empty: Encodable, Sendable {}
        return try await client.post("system/databases/integrity", body: Empty(), returning: [String: SystemDatabase.IntegrityRun].self)
    }
    // Stream the online SQLite archive to a protected file instead of holding it in memory.
    func backup(directory: URL) async throws -> URL {
        let transport = try client
        var request = try transport.request("db-backup", method: "GET")
        request.timeoutInterval = 10 * 60
        let (temporary, response) = try await transport.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse(statusCode: 0) }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.serverError(message: response.statusCode == 429 ? "Another database backup is running. Try again shortly." : "Database backup failed (HTTP \(response.statusCode)).")
        }
        guard ["application/gzip", "application/x-gzip"].contains(response.mimeType ?? "") else {
            throw APIError.serverError(message: "The controller did not return a database archive.")
        }
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent("sleepypod-databases-\(Int(Date.now.timeIntervalSince1970)).tar.gz")
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var protectedURL = destination; try protectedURL.setResourceValues(resource)
        return destination
    }
}

struct DemoSystemDatabaseClient: SystemDatabaseClient {
    func overview(fresh: Bool) throws -> SystemDatabaseOverview {
        let file = Bundle.main.url(forResource: "system-database-fixture", withExtension: "json")
        guard let file else { throw APIError.serverError(message: "Database demo is unavailable.") }
        return try JSONDecoder().decode(SystemDatabaseOverview.self, from: Data(contentsOf: file))
    }
    func rows(_ query: SystemDatabaseQuery) throws -> SystemDatabaseRows {
        if let message = query.validation { throw APIError.serverError(message: message) }
        let values: [[SystemDatabaseRows.Cell]] = (1...23).reversed().map {
            [.number(Double($0)), .text($0.isMultiple(of: 2) ? "left" : "right"), .number(1_792_900_000 + Double($0) * 60), .number(Double(50 + $0))]
        }
        let columns = ["id", "side", "timestamp", "value"]
        let filtered: [[SystemDatabaseRows.Cell]]
        if let column = query.column, let value = query.value, let index = columns.firstIndex(of: column) { filtered = values.filter { $0[index].display == value } }
        else { filtered = values }
        return .init(columns: columns, timeColumn: "timestamp", rows: Array(filtered.dropFirst(query.offset).prefix(query.limit)), total: filtered.count)
    }
    func integrity() throws -> [String: SystemDatabase.IntegrityRun] { throw APIError.serverError(message: "Demo has no database files to check.") }
    func backup(directory: URL) throws -> URL { throw APIError.serverError(message: "Demo has no controller databases to download.") }
}
