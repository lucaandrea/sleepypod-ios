import Foundation

/// Fixed report routes only. A failed or interrupted mutation is never automatically replayed.
public struct MorningReportHTTPClient: MorningReportSharingTransport {
    private let endpoint: URL
    private let token: String
    private let scope: MorningReportScope
    private let transport: URLSession
    private let now: @Sendable () -> Date

    public init(endpoint: URL, token: String, scope: MorningReportScope) throws {
        try self.init(endpoint: endpoint, token: token, scope: scope, transport: Self.transport)
    }
    init(endpoint: URL, token: String, scope: MorningReportScope, transport: URLSession,
         now: @escaping @Sendable () -> Date = { .now }) throws {
        guard try ConnectionEndpoint.url(endpoint.absoluteString) == endpoint,
              !token.isEmpty, token.utf8.count <= 4096,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw MorningReportSharingFailure.authentication
        }
        self.endpoint = endpoint; self.token = token; self.scope = scope; self.transport = transport; self.now = now
    }
    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: MorningReportRedirectPolicy(), delegateQueue: nil)
    }()

    public func read(id: UUID) async throws -> MorningReportSharedCopy? { try await request(id: id, method: "GET") }

    public func share(id: UUID, document: Data, expectedRevision: UUID?) async throws -> MorningReportSharedCopy {
        guard document.count <= MorningReportTransfer.maximumBytes,
              let object = try JSONSerialization.jsonObject(with: document) as? [String: Any],
              Set(object.keys) == ["version", "report"], MorningReportWire.integer(object["version"]) == 1,
              let report = object["report"] as? [String: Any],
              (report["id"] as? String).flatMap(UUID.init(uuidString:)) == id else { throw MorningReportSharingFailure.invalid }
        let body = try JSONSerialization.data(withJSONObject: ["expectedRevision": expectedRevision?.uuidString.lowercased() as Any? ?? NSNull(), "document": object])
        guard let result = try await request(id: id, method: "PUT", body: body), !result.receipt.deleted else {
            throw MorningReportSharingFailure.invalid
        }
        return result
    }

    public func withdraw(id: UUID, expectedRevision: UUID?) async throws -> MorningReportSharedCopy {
        let body = try JSONSerialization.data(withJSONObject: ["expectedRevision": expectedRevision?.uuidString.lowercased() as Any? ?? NSNull()])
        guard let result = try await request(id: id, method: "DELETE", body: body), result.receipt.deleted else {
            throw MorningReportSharingFailure.invalid
        }
        return result
    }

    private func request(id: UUID, method: String, body: Data? = nil) async throws -> MorningReportSharedCopy? {
        try Task.checkCancellation()
        let address = endpoint.appending(path: scope.route).appending(path: id.uuidString.lowercased())
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let sleeper = scope.sleeperID { request.setValue(sleeper.uuidString.lowercased(), forHTTPHeaderField: "X-Sleepypod-Sleeper-Id") }
        do {
            let (bytes, response) = try await transport.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.url == address else { throw MorningReportSharingFailure.invalid }
            switch response.statusCode {
            case 200, 404: break
            case 401: throw MorningReportSharingFailure.authentication
            case 403: throw MorningReportSharingFailure.forbidden
            case 409: throw MorningReportSharingFailure.conflict
            case 429, 503: throw MorningReportSharingFailure.unavailable
            default: throw MorningReportSharingFailure.uncertain
            }
            let limit = response.statusCode == 404 ? 8192 : 512 * 1024
            guard response.mimeType == "application/json", response.expectedContentLength <= limit else { throw MorningReportSharingFailure.invalid }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw MorningReportSharingFailure.invalid }; data.append(byte)
            }
            try Task.checkCancellation()
            if response.statusCode == 404 {
                struct Missing: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
                guard method == "GET", (try? JSONDecoder().decode(Missing.self, from: data).error.code) == "not_found" else {
                    throw MorningReportSharingFailure.unavailable
                }
                return nil
            }
            do { return try MorningReportWire.reply(data, id: id, scope: scope, now: now()) }
            catch { throw MorningReportSharingFailure.invalid }
        } catch let failure as MorningReportSharingFailure { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw MorningReportSharingFailure.uncertain }
    }
}

private final class MorningReportRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
