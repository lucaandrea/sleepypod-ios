import Foundation
import FreeSleepKit

protocol HouseholdTransport: Sendable {
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data
}

struct HouseholdHTTPClient: HouseholdTransport {
    let endpoint: URL
    var session: URLSession = Self.session
    private static let session = URLSession(configuration: .ephemeral, delegate: HouseholdRedirectPolicy(), delegateQueue: nil)
    static let methods: [String: Set<String>] = [
        "household/session": ["GET"], "household/setup": ["POST"], "household/join": ["POST"],
        "household/invitations": ["GET", "POST", "DELETE"], "household/devices": ["GET", "DELETE"],
        "me/preferences": ["GET", "PUT"], "me/routines": ["GET", "PUT"]
    ]
    static func endpoint(_ address: String) throws -> URL { try UnifiedRuntime.validatedEndpoint(address) }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        guard Self.methods[path]?.contains(method) == true, try Self.endpoint(endpoint.absoluteString) == endpoint else { throw HouseholdFailure.invalid }
        var request = URLRequest(url: endpoint.appending(path: "api/v1").appending(path: path))
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            guard !token.isEmpty, !token.contains(where: { $0.isNewline || $0 == "\r" }) else { throw HouseholdFailure.authentication }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw HouseholdFailure.uncertain }
        guard let response = response as? HTTPURLResponse, data.count <= 524_288,
              response.url?.host == endpoint.host, response.url?.scheme == endpoint.scheme,
              response.url?.port == endpoint.port else { throw HouseholdFailure.invalid }
        guard (200..<300).contains(response.statusCode) else {
            struct Envelope: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
            let code = (try? JSONDecoder().decode(Envelope.self, from: data))?.error.code
            switch code {
            case "authentication_required": throw HouseholdFailure.authentication
            case "setup_required", "not_ready": throw HouseholdFailure.unavailable
            case "forbidden": throw HouseholdFailure.forbidden
            case "conflict": throw HouseholdFailure.conflict
            case "invitation_unavailable": throw HouseholdFailure.invitation
            case "rate_limited": throw HouseholdFailure.rateLimited
            case "invalid_request": throw HouseholdFailure.invalid
            default:
                if response.statusCode == 401 { throw HouseholdFailure.authentication }
                if response.statusCode == 404 { throw HouseholdFailure.unavailable }
                throw HouseholdFailure.uncertain
            }
        }
        return data
    }
}

private final class HouseholdRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

enum HouseholdRequestBody {
    static func context(_ session: HouseholdSession, requestId: UUID = UUID()) -> [String: Any] {
        ["requestId": requestId.uuidString, "expectedSessionRevision": session.sessionRevision, "expectedAssignmentRevision": session.assignmentRevision]
    }
    static func data(_ values: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) }
    static func object<Value: Encodable>(_ value: Value) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
}

struct HouseholdPreparationCapability: Decodable, Sendable {
    struct Feature: Decodable, Sendable { let implemented: Bool; let runtime: String }
    struct Features: Decodable, Sendable { let householdPreparation: Feature? }
    let apiVersion: Int
    let features: Features?
    var ready: Bool { apiVersion == 1 && features?.householdPreparation?.implemented == true && features?.householdPreparation?.runtime == "ready" }
    static func load() async throws -> Bool {
        let value: Self = try await CoreRESTClient.configured().get("v1/capabilities")
        return value.ready
    }
}
