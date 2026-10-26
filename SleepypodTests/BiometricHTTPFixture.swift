import XCTest
@testable import Sleepypod

final class BiometricHTTPFixture {
    let host = "biometrics-\(UUID().uuidString.lowercased()).invalid"
    let state = BiometricHTTPState()
    let session: URLSession
    var transport: CoreRESTClient { .init(endpoint: URL(string: "https://\(host)")!, session: session) }
    init() {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BiometricHTTPProtocol.self]
        session = URLSession(configuration: config); BiometricHTTPProtocol.registry.register(state, host: host)
    }
    func close() { session.invalidateAndCancel(); BiometricHTTPProtocol.registry.remove(host) }
}
final class BiometricHTTPState: @unchecked Sendable {
    struct Request { let method: String; let path: String; let query: [String: String]; let body: [String: Any] }
    private let lock = NSLock()
    private var values: [Data] = []
    private var writesFail = false
    private var received: [Request] = []
    var responses: [Data] { get { lock.withLock { values } } set { lock.withLock { values = newValue } } }
    var failWrites: Bool { get { lock.withLock { writesFail } } set { lock.withLock { writesFail = newValue } } }
    var requests: [Request] { lock.withLock { received } }
    func reply(_ request: URLRequest) throws -> Data {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        let body = data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return try lock.withLock {
            received.append(.init(method: request.httpMethod ?? "", path: request.url!.path, query: Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }), body: body))
            if writesFail && request.httpMethod != "GET" { throw URLError(.timedOut) }
            guard !values.isEmpty else { throw URLError(.badServerResponse) }; return values.removeFirst()
        }
    }
}
final class BiometricHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: BiometricHTTPState] = [:]
    func register(_ state: BiometricHTTPState, host: String) { lock.withLock { values[host] = state } }
    func remove(_ host: String) { _ = lock.withLock { values.removeValue(forKey: host) } }
    func state(_ host: String) -> BiometricHTTPState? { lock.withLock { values[host] } }
}
final class BiometricHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = BiometricHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host.flatMap(registry.state) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let state = Self.registry.state(url.host ?? "") else { return }
        do {
            let data = try state.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
