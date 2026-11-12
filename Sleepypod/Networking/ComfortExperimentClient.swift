import Foundation
import FreeSleepKit

struct ComfortExperimentAccess: Equatable, Sendable {
    let scope: ComfortExperimentScope
    let revision: [String]
    let execution: Bool
}

enum ComfortExperimentFailure: Error, LocalizedError, Equatable {
    case reason(String)
    var errorDescription: String? {
        switch self {
        case .reason(let message): message
        }
    }
}

/// Only fixed comparison operations are expressible; callers cannot choose an actuator route, sleeper or hardware evidence.
enum ComfortExperimentRequest: Sendable {
    case library(after: String? = nil), detail(String), preview(ComfortExperimentProposal), save(reviewId: String, hash: String)
    case stop(id: String, revision: String), feedback(id: String, revision: String, value: ComfortExperimentFeedback)
    case execution(String), reviewControl(String), confirmControl(id: String, reviewId: String, hash: String)
    case cancelControl(id: String, admissionId: String), recover(id: String, admissionId: String, applicationId: String)

    struct Payload: Sendable { let path: String; let query: [URLQueryItem]; let body: Data? }
    func payload() throws -> Payload {
        var path = "", query: [URLQueryItem] = [], body: [String: Any]?
        func identifier(_ value: String) throws -> String {
            try ComfortExperimentContract.require(ComfortExperimentContract.identifier(value)); return value
        }
        func hash(_ value: String) throws -> String {
            try ComfortExperimentContract.require(ComfortExperimentContract.hash(value)); return value
        }
        switch self {
        case .library(let after):
            if let after { query = [.init(name: "afterId", value: try identifier(after))] }
        case .detail(let id): path = try identifier(id)
        case .preview(let proposal):
            try proposal.validate(); path = "preview"; body = ["firstNightDate": proposal.firstNightDate, "variantF": proposal.variantF]
        case .save(let reviewId, let planHash): path = "confirm"; body = ["reviewId": try identifier(reviewId), "planHash": try hash(planHash)]
        case .stop(let id, let revision): path = try identifier(id) + "/stop"; body = ["expectedRevision": try identifier(revision)]
        case .feedback(let id, let revision, let value):
            try value.validate(); path = try identifier(id) + "/feedback"
            body = ["expectedRevision": try identifier(revision), "feedback": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))]
        case .execution(let id): path = try identifier(id) + "/execution"
        case .reviewControl(let id): path = try identifier(id) + "/execution/preview"; body = [:]
        case .confirmControl(let id, let reviewId, let planHash):
            path = try identifier(id) + "/execution/confirm"
            body = ["reviewId": try identifier(reviewId), "planHash": try hash(planHash), "confirmed": true]
        case .cancelControl(let id, let admissionId):
            path = try identifier(id) + "/execution/cancel"; body = ["admissionId": try identifier(admissionId)]
        case .recover(let id, let admissionId, let applicationId):
            path = try identifier(id) + "/execution/recover"
            body = ["admissionId": try identifier(admissionId), "applicationId": try identifier(applicationId), "confirmed": true]
        }
        return .init(path: path, query: query, body: try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) })
    }
    var needsExecution: Bool {
        switch self {
        case .execution, .reviewControl, .confirmControl, .cancelControl, .recover: true
        default: false
        }
    }
}

protocol ComfortExperimentTransport: Sendable {
    func access() async throws -> ComfortExperimentAccess
    func request(_ action: ComfortExperimentRequest) async throws -> Data
}

struct ComfortExperimentHTTPClient: ComfortExperimentTransport {
    enum Account: Sendable { case owner(CoreRESTClient, revision: [String]); case personal(PersonalBedConnection) }
    let account: Account
    var session: URLSession = Self.session
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration, delegate: PersonalHistoryRedirectPolicy(), delegateQueue: nil)
    }()
    func access() async throws -> ComfortExperimentAccess {
        switch account {
        case .owner(_, let revision):
            guard revision == OwnerConnection.revision, !PersonalWorkspaceBoundary.isActive else { throw HouseholdFailure.changedIdentity }
            let challenge = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
            let data = try await send(path: "connection", query: [.init(name: "challenge", value: challenge)])
            struct Identity: Decodable { let schemaVersion: Int; let controller: String; let installationId: String; let challenge: String }
            let identity = try JSONDecoder().decode(Identity.self, from: data)
            let scope = ComfortExperimentScope(kind: "legacy", installationId: identity.installationId)
            try scope.validate()
            guard revision == OwnerConnection.revision, !PersonalWorkspaceBoundary.isActive else { throw HouseholdFailure.changedIdentity }
            try ComfortExperimentContract.require(identity.schemaVersion == 1 && identity.controller == "sleepypod-core"
                && identity.challenge == challenge)
            return .init(scope: scope, revision: revision, execution: true)
        case .personal(let connection):
            let fresh = try JSONDecoder().decode(HouseholdSession.self, from: await send(path: "household/session"))
            try fresh.validate()
            guard fresh == connection.session else { throw HouseholdFailure.changedIdentity }
            guard fresh.capabilities.comfortExperiments == true else { throw HouseholdFailure.unavailable }
            return .init(scope: .personal(fresh), revision: fresh.context + [String(fresh.householdRevision)], execution: fresh.capabilities.comfortExperimentExecution == true)
        }
    }
    func request(_ action: ComfortExperimentRequest) async throws -> Data {
        let payload = try action.payload()
        let prefix: String
        switch account {
        case .owner: prefix = "comfort/experiments"
        case .personal(let connection):
            guard connection.session.capabilities.comfortExperiments == true,
                  !action.needsExecution || connection.session.capabilities.comfortExperimentExecution == true else { throw HouseholdFailure.unavailable }
            prefix = "me/comfort-experiments"
        }
        return try await send(path: prefix + (payload.path.isEmpty ? "" : "/" + payload.path), query: payload.query, body: payload.body)
    }
    private func send(path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var request: URLRequest
        switch account {
        case .owner(let client, let revision):
            guard revision == OwnerConnection.revision, !PersonalWorkspaceBoundary.isActive else { throw HouseholdFailure.changedIdentity }
            request = try client.request("v1/" + path, method: body == nil ? "GET" : "POST",
                query: Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }), body: body)
            guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true else { throw HouseholdFailure.authentication }
        case .personal(let connection):
            guard try HouseholdHTTPClient.endpoint(connection.endpoint.absoluteString) == connection.endpoint,
                  HouseholdValidation.secret(connection.token) else { throw HouseholdFailure.authentication }
            let endpoint = connection.endpoint.appending(path: "api/v1/" + path)
            guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw HouseholdFailure.invalid }
            if !query.isEmpty { parts.queryItems = query }
            guard let address = parts.url else { throw HouseholdFailure.invalid }
            request = URLRequest(url: address); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
            request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
            request.setValue(connection.session.selfSleeperId, forHTTPHeaderField: "X-Sleepypod-Sleeper-Id")
        }
        request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, response.url == request.url,
                  response.mimeType == "application/json", response.expectedContentLength <= 524_288 else { throw HouseholdFailure.invalid }
            var data = Data()
            for try await byte in bytes { guard data.count < 524_288 else { throw HouseholdFailure.invalid }; data.append(byte) }
            try Task.checkCancellation()
            if response.statusCode == 401 { throw HouseholdFailure.authentication }
            if response.statusCode == 403 { throw HouseholdFailure.forbidden }
            guard (200..<300).contains(response.statusCode) else {
                struct Failure: Decodable { struct Detail: Decodable { let code: String; let message: String }; let error: Detail }
                if let failure = try? JSONDecoder().decode(Failure.self, from: data),
                   ["invalid_request", "conflict", "not_found", "not_ready"].contains(failure.error.code),
                   !failure.error.message.isEmpty, failure.error.message.utf16.count <= 2000 {
                    throw ComfortExperimentFailure.reason(failure.error.message)
                }
                throw HouseholdFailure.uncertain
            }
            return data
        } catch let failure as HouseholdFailure { throw failure }
        catch let failure as ComfortExperimentFailure { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw HouseholdFailure.uncertain }
    }
}
