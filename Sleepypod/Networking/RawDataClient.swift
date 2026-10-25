import Foundation

protocol RawDataClient: Sendable {
    func files() async throws -> [RawSensorFile]
    func usage() async throws -> RawDiskUsage
    func delete(_ file: RawSensorFile) async throws
    func download(_ file: RawSensorFile, directory: URL) async throws -> URL
    func archive(start: Date, end: Date, directory: URL) async throws -> URL
}

struct CoreRawDataClient: RawDataClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func files() async throws -> [RawSensorFile] { try await client.get("raw/files") }
    func usage() async throws -> RawDiskUsage { try await client.get("raw/disk-usage") }
    func delete(_ file: RawSensorFile) async throws {
        guard RawSensorFile.validName(file.name) else { throw APIError.serverError(message: "Invalid sensor filename.") }
        struct Request: Encodable { let filename: String }
        struct Response: Decodable { let deleted: Bool; let message: String }
        let response: Response = try await client.post("raw/files/delete", body: Request(filename: file.name), returning: Response.self)
        guard response.deleted else { throw APIError.serverError(message: response.message) }
    }
    func download(_ file: RawSensorFile, directory: URL) async throws -> URL {
        guard RawSensorFile.validName(file.name) else { throw APIError.serverError(message: "Invalid sensor filename.") }
        return try await transfer(path: "raw/\(file.name)", query: [:], filename: file.name, directory: directory)
    }
    func archive(start: Date, end: Date, directory: URL) async throws -> URL {
        guard end > start else { throw APIError.serverError(message: "Choose a valid export range.") }
        let lower = String(Int(start.timeIntervalSince1970)), upper = String(Int(end.timeIntervalSince1970))
        return try await transfer(path: "export/archive", query: ["startTs": lower, "endTs": upper, "include": "raw,db"],
                                  filename: "sleepypod-\(lower)-\(upper).tar.gz", directory: directory)
    }
    // URLSession writes streamed archives to disk, avoiding a multi-gigabyte in-memory Data allocation.
    private func transfer(path: String, query: [String: String], filename: String, directory: URL) async throws -> URL {
        let client = try client
        var request = try client.request(path, method: "GET", query: query)
        request.timeoutInterval = 30 * 60
        let (temporary, response) = try await client.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.serverError(message: "Download failed (HTTP \(status)). Try again when the controller is available.")
        }
        let mime = response.mimeType ?? ""
        guard ["application/octet-stream", "application/gzip", "application/x-gzip", "application/x-tar"].contains(mime) else {
            throw APIError.serverError(message: "The controller did not return a data file.")
        }
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        return destination
    }
}

actor DemoRawDataClient: RawDataClient {
    private var samples = (0..<3).map { index in
        RawSensorFile(name: String(format: "%08X.RAW", 0x1054 - index), sizeBytes: 30_000_000 + Int64(index) * 12_000_000,
                      modifiedAt: Date.now.addingTimeInterval(Double(-index) * 7200).ISO8601Format())
    }
    func files() -> [RawSensorFile] { samples }
    func usage() -> RawDiskUsage { RawDiskUsage(totalBytes: 8_000_000_000, usedBytes: 5_700_000_000, availableBytes: 2_300_000_000,
                                               rawFileCount: samples.count, rawBytes: samples.reduce(0) { $0 + $1.sizeBytes }) }
    func delete(_ file: RawSensorFile) throws {
        guard samples.first?.name != file.name else { throw APIError.serverError(message: "The active sensor file cannot be deleted.") }
        samples.removeAll { $0.name == file.name }
    }
    func download(_ file: RawSensorFile, directory: URL) throws -> URL { throw APIError.serverError(message: "Demo mode has no sensor files to download.") }
    func archive(start: Date, end: Date, directory: URL) throws -> URL { throw APIError.serverError(message: "Demo mode has no controller archive to download.") }
}
