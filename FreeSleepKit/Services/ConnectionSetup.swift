import Foundation
import Observation

struct ConnectionInput: Equatable, Sendable { var address: String; var token: String }
struct ConnectionIdentity: Equatable, Sendable {
    var id: String
    var timeZone: String
    static let demo = ConnectionIdentity(id: "Demo Pod", timeZone: "America/Los_Angeles")
    init(id: String, timeZone: String) { self.id = id; self.timeZone = timeZone }
    init(settings: PodSettings) throws {
        guard !settings.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              TimeZone(identifier: settings.timeZone) != nil, ["celsius", "fahrenheit"].contains(settings.temperatureFormat) else {
            throw PodError.message("This address did not return valid Pod settings.")
        }
        id = settings.id; timeZone = settings.timeZone
    }
}

enum ConnectionEndpoint {
    static func url(_ address: String) throws -> URL {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: clean), let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              !host.isEmpty, ["http", "https"].contains(scheme), parts.user == nil, parts.password == nil,
              ["", "/"].contains(parts.percentEncodedPath), parts.query == nil, parts.fragment == nil else {
            throw PodError.message("Use a complete server address without a path, query, fragment or embedded credentials.")
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { Int($0) }
        let privateIP = labels.count == 4 && octets.count == 4 && octets.allSatisfy { (0...255).contains($0) }
            && (octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])))
        guard scheme == "https" || host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") || privateIP else {
            throw PodError.message("Use HTTPS for a remote connection, or an address on your home network.")
        }
        parts.scheme = scheme; parts.host = host; parts.path = ""
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        guard let url = parts.url else { throw PodError.message("Enter a valid server address.") }
        return url
    }
}

@MainActor @Observable
final class ConnectionSetup {
    var address: String { didSet { if address != oldValue { token = ""; invalidate() } } }
    var token: String { didSet { if token != oldValue { invalidate() } } }
    private(set) var result: ConnectionIdentity?
    private(set) var failure: String?
    private(set) var message: String?
    private(set) var testing = false
    let demo: Bool
    private var generation = UUID()
    init(demo: Bool, load: () -> ConnectionInput) {
        self.demo = demo
        let input = demo ? ConnectionInput(address: "https://demo-pod.example", token: "") : load()
        address = input.address; token = input.token
    }
    func invalidate() { generation = UUID(); result = nil; failure = nil; message = nil; testing = false }
    private func input() throws -> ConnectionInput {
        .init(address: try ConnectionEndpoint.url(address).absoluteString, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    // A test owns its input snapshot; leaving or changing the form retires the result.
    func check(_ probe: (ConnectionInput) async throws -> ConnectionIdentity) async {
        guard !testing else { return }
        invalidate(); let current = generation; testing = true
        defer { if current == generation { testing = false } }
        do {
            let value = try input()
            let identity = demo ? ConnectionIdentity.demo : try await probe(value)
            guard !Task.isCancelled, current == generation else { return }; result = identity
        } catch {
            guard !Task.isCancelled, current == generation else { return }; failure = error.localizedDescription
        }
    }
    func save(_ persist: (ConnectionInput) throws -> Void) {
        guard !testing else { return }
        failure = nil; message = nil
        do {
            let value = try input()
            if demo { message = "Demo connection saved for this preview. Your saved connection is unchanged."; return }
            try persist(value)
            message = result == nil ? "Connection saved. Test not run for these details." : "Connection saved."
        } catch { failure = error.localizedDescription }
    }
}
