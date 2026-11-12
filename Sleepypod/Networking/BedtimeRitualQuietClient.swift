import Foundation

/// Installation and personal credentials use distinct read-only routes, with no fallback between them.
struct BedtimeRitualQuietClient: Sendable {
    enum Account: Sendable { case owner(UUID), personal(HouseholdSession) }
    let endpoint: URL
    let token: String
    let scope: String
    let account: Account
    var transport: URLSession = Self.transport
    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: PersonalHistoryRedirectPolicy(), delegateQueue: nil)
    }()

    func read() async throws -> BedtimeRitualQuiet {
        guard BedtimeRitualClock.scope(scope), !token.isEmpty,
              try HouseholdHTTPClient.endpoint(endpoint.absoluteString) == endpoint else { throw BedtimeRitualFailure.invalid }
        switch account {
        case .owner(let installation):
            let candidate = try OwnerConnectionCandidate(address: endpoint.absoluteString, streamAddress: "", backend: .sleepypodCore, token: token)
            let identity = ControllerIdentityClient(session: transport)
            guard try await identity.read(candidate) == installation else { throw BedtimeRitualFailure.accountChanged }
            let data = try await request("household/shared-quiet")
            let result = try Self.ownerReading(data, scope: scope)
            guard try await identity.read(candidate) == installation else { throw BedtimeRitualFailure.accountChanged }
            return result
        case .personal(let expected):
            try expected.validate()
            guard expected.capabilities.householdQuiet == true else { throw BedtimeRitualFailure.quietUnavailable }
            try await checkSession(expected)
            let page = try PersonalQuietPage.decodeExact(await request("me/quiet"))
            try page.validate(for: expected)
            try await checkSession(expected)
            return .init(scope: scope, generatedAt: Date(timeIntervalSince1970: Double(page.generatedAt) / 1000),
                expiresAt: Date(timeIntervalSince1970: Double(page.generatedAt + PersonalQuietContract.observationLifetime) / 1000),
                paused: page.shared.paused, until: page.shared.until.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }
    private func checkSession(_ expected: HouseholdSession) async throws {
        let session = try JSONDecoder().decode(HouseholdSession.self, from: await request("household/session"))
        try session.validate()
        guard session == expected else { throw BedtimeRitualFailure.accountChanged }
    }
    static func ownerReading(_ data: Data, scope: String) throws -> BedtimeRitualQuiet {
        struct Envelope: Decodable { let version: Int; let generatedAt: Int64; let expiresAt: Int64; let shared: PersonalQuietPage.Shared }
        let object = try JSONSerialization.jsonObject(with: data)
        try PersonalQuietContract.keys(object, ["version", "generatedAt", "expiresAt", "shared"])
        try PersonalQuietContract.keys((object as? [String: Any])?["shared"], ["paused", "until"])
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.version == 1, PersonalQuietContract.instant(value.generatedAt), PersonalQuietContract.instant(value.expiresAt),
              value.expiresAt - value.generatedAt == PersonalQuietContract.observationLifetime,
              value.shared.paused == (value.shared.until != nil),
              value.shared.until.map({ PersonalQuietContract.instant($0) && $0 > value.generatedAt }) ?? true
        else { throw BedtimeRitualFailure.invalid }
        return .init(scope: scope, generatedAt: Date(timeIntervalSince1970: Double(value.generatedAt) / 1000),
            expiresAt: Date(timeIntervalSince1970: Double(value.expiresAt) / 1000), paused: value.shared.paused,
            until: value.shared.until.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }
    private func request(_ path: String) async throws -> Data {
        let allowed: Set<String> = switch account {
        case .owner: ["household/shared-quiet"]
        case .personal: ["household/session", "me/quiet"]
        }
        guard allowed.contains(path) else { throw BedtimeRitualFailure.invalid }
        let address = endpoint.appending(path: "api/v1").appending(path: path)
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if case .personal(let session) = account { request.setValue(session.selfSleeperId, forHTTPHeaderField: "X-Sleepypod-Sleeper-Id") }
        let (bytes, response) = try await transport.bytes(for: request)
        defer { bytes.task.cancel() }
        if let response = response as? HTTPURLResponse, [401, 403].contains(response.statusCode) {
            throw BedtimeRitualFailure.accountChanged
        }
        guard let response = response as? HTTPURLResponse, response.url == address,
              response.statusCode == 200, response.mimeType == "application/json", response.expectedContentLength <= 16_384
        else { throw BedtimeRitualFailure.quietUnavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16_384 else { throw BedtimeRitualFailure.invalid }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}
