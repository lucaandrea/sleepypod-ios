import Foundation
import Testing
@testable import FreeSleepKit

// Every request from the fixture's ephemeral session is intercepted, including unexpected URLs.
final class IntentHTTPFixture: @unchecked Sendable {
    // Simulator UI tests persist Demo. Isolate HTTP fixtures in this test process;
    // do not change the app's saved preferences or its production demo guard.
    private static let isolatedDefaults: Void = {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["apiBackend"] = "free-sleep"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }()

    struct Reply: Sendable {
        var status = 204
        var body = Data()
        init(status: Int = 204, json: String = "") { self.status = status; body = Data(json.utf8) }
        init(data: Data) { status = 200; body = data }
    }
    typealias Responder = @Sendable (URLRequest) throws -> Reply
    let client: PodClient
    private let session: URLSession
    private let host: String
    private let capture: Capture
    init(token: String = "synthetic-token", apiPrefix: String = "", responder: @escaping Responder = { _ in Reply() }) throws {
        _ = Self.isolatedDefaults
        host = "fixture-\(UUID().uuidString.lowercased()).example"
        let capture = Capture(responder: responder); self.capture = capture
        IntentHTTPProtocol.registry.insert(capture, for: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntentHTTPProtocol.self]
        session = URLSession(configuration: configuration)
        client = try PodClient(address: "https://\(host)", token: token, session: session, apiPrefix: apiPrefix)
    }
    func close() { session.invalidateAndCancel(); IntentHTTPProtocol.registry.remove(host) }
    var requests: [URLRequest] { capture.requests }
    func expect(_ index: Int, method: String = "POST", path: String, query: String? = nil,
                body: [String: Any]? = nil, token: String = "synthetic-token") throws {
        let request = try #require(requests.indices.contains(index) ? requests[index] : nil)
        #expect(request.httpMethod == method); #expect(request.url?.path == "/api/" + path)
        #expect(request.url?.query == query)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        if let body {
            let received = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? NSDictionary
            #expect(received == NSDictionary(dictionary: body))
        } else { #expect(request.httpBody == nil) }
    }
    fileprivate final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [URLRequest] = []
        private let responder: Responder
        init(responder: @escaping Responder) { self.responder = responder }
        var requests: [URLRequest] { lock.withLock { captured } }
        func reply(_ request: URLRequest) throws -> Reply {
            lock.withLock { captured.append(request) }
            return try responder(request)
        }
    }
}

private final class IntentHTTPProtocol: URLProtocol, @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var captures: [String: IntentHTTPFixture.Capture] = [:]
        func insert(_ capture: IntentHTTPFixture.Capture, for host: String) { lock.withLock { captures[host] = capture } }
        func remove(_ host: String) { lock.withLock { _ = captures.removeValue(forKey: host) } }
        func capture(for host: String) -> IntentHTTPFixture.Capture? { lock.withLock { captures[host] } }
    }
    static let registry = Registry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let url = request.url, let host = url.host, let capture = Self.registry.capture(for: host) else {
                throw URLError(.unsupportedURL)
            }
            var captured = request
            // URLSession may represent a JSON body as a stream when handing it to URLProtocol.
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                captured.httpBody = data
            }
            let reply = try capture.reply(captured)
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
