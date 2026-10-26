import Foundation
import Network
import XCTest
@testable import Sleepypod

@MainActor final class SystemDatabaseBackupTests: XCTestCase {
    func testBackupDownloadPreservesBytesAndRemovesTemporaryExport() async throws {
        let payload = Data([0x1f, 0x8b, 0x08, 0x00]) + Data(repeating: 0x42, count: 8192)
        let server = try DatabaseBackupFixtureServer(status: 200, mime: "application/gzip", body: payload)
        let endpoint = try await server.start(); defer { server.stop() }
        let client = CoreSystemDatabaseClient(transport: .init(endpoint: endpoint))
        let model = SystemDatabaseWorkspace(client: client)
        await model.downloadBackup()
        XCTAssertNil(model.error)
        let file = try XCTUnwrap(model.backupURL)
        XCTAssertEqual(try Data(contentsOf: file), payload)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
        model.removeBackup()
        XCTAssertNil(model.backupURL); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testBackupRejectsBusyControllerAndNonArchiveResponse() async throws {
        for (status, mime, expected) in [(429, "application/json", "Another database backup"), (200, "text/html", "did not return a database archive")] {
            let server = try DatabaseBackupFixtureServer(status: status, mime: mime, body: Data("not an archive".utf8))
            let endpoint = try await server.start(); defer { server.stop() }
            let model = SystemDatabaseWorkspace(client: CoreSystemDatabaseClient(transport: .init(endpoint: endpoint)))
            await model.downloadBackup()
            XCTAssertNil(model.backupURL); XCTAssertTrue(model.error?.contains(expected) == true)
        }
    }
}

/// Loopback HTTP fixture exercises URLSession's real streamed-download path; it never contacts a Pod.
private final class DatabaseBackupFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "database-backup-fixture")
    private let response: Data
    init(status: Int, mime: String, body: Data) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        response = Data("HTTP/1.1 \(status) Fixture\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }
    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: queue)
            receive(connection, accumulated: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
                        continuation.resume(throwing: URLError(.badURL)); return
                    }
                    continuation.resume(returning: url)
                case .failed(let error):
                    listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, complete, error in
            let bytes = accumulated + (data ?? Data())
            if let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") {
                XCTAssertTrue(text.hasPrefix("GET /api/db-backup HTTP/1.1\r\n"))
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if error != nil || complete || bytes.count > 32_768 { connection.cancel() }
            else { receive(connection, accumulated: bytes) }
        }
    }
    func stop() { listener.cancel() }
}
