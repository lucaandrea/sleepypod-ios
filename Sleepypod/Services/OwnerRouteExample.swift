#if DEBUG
import Foundation

/// Runs the real enrollment coordinator with private in-memory fixtures, never Keychain or a Pod.
@MainActor final class OwnerRouteExample {
    private var revision = ["sleepypod-core", "http://10.0.0.123:3000", "10.0.0.123", "example-owner", "example-boundary"]
    private var keys = ["http://10.0.0.123:3000": "synthetic-route-home-credential-never-real",
                        "https://bedroom.example.invalid": "synthetic-route-away-credential-never-real"]
    private var profile: EnrolledOwnerRoutes?
    private let installation = UUID()
    private let scenario: String

    init(scenario: String) throws {
        self.scenario = scenario
        let home = try OwnerConnectionCandidate(address: revision[1], streamAddress: "", backend: .sleepypodCore, token: keys[revision[1]] ?? "")
        let away = try OwnerConnectionCandidate(address: "https://bedroom.example.invalid", streamAddress: "", backend: .sleepypodCore,
                                                token: keys["https://bedroom.example.invalid"] ?? "")
        var routes = try VerifiedOwnerRoutes(installationID: installation, credentialRevision: revision[3], home: home, away: away, now: Date())
        routes.enabled = false
        profile = try EnrolledOwnerRoutes(routes: routes, currentRevision: revision)
    }

    static func configured() -> OwnerRouteSession? {
        guard APIBackend.current.isDemo, let scenario = UserDefaults.standard.string(forKey: "uiRouteExample"),
              let example = try? OwnerRouteExample(scenario: scenario) else { return nil }
        return example.session()
    }

    private func session() -> OwnerRouteSession {
        OwnerRouteSession(revision: { self.revision }, allowed: { APIBackend.current.isDemo }, key: { self.keys[$0] ?? "" },
            saveKey: { self.keys[$0] = $1 }, load: { revision in
                try self.profile?.validateContext(revision)
                return self.profile
            }, save: { profile, revision in
                try profile.validateContext(revision); self.profile = profile
            }, establishRevision: { self.revision[3] = $0 }, identity: { candidate in
                guard APIBackend.current.isDemo else { throw CancellationError() }
                if candidate.endpoint.scheme == "https" {
                    if self.scenario == "authentication" { throw APIError.invalidResponse(statusCode: 401) }
                    if self.scenario == "network" { throw URLError(.cannotConnectToHost) }
                    if self.scenario == "different" { return UUID() }
                }
                return self.installation
            })
    }
}
#endif
