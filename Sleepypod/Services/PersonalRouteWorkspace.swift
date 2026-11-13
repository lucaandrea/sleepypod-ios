import Foundation
import Observation

@MainActor @Observable final class PersonalRouteWorkspace {
    typealias Read = @MainActor (URL, String) async throws -> HouseholdSession
    private(set) var busy = false
    private(set) var message: String?
    private(set) var lastFailure: HouseholdFailure?
    private(set) var verifiedSession: HouseholdSession?
    private(set) var verifiedEndpoint: URL?
    var editing = false
    private var generation = UUID()
    private let read: Read

    init(read: @escaping Read = { try await PersonalRouteClient().read(endpoint: $0, token: $1) }) { self.read = read }
    func invalidate() { generation = UUID(); busy = false; message = nil; verifiedEndpoint = nil; verifiedSession = nil; lastFailure = nil }

    /// Both addresses are explicitly reviewed before the personal key is sent to either origin.
    func enroll(record: HouseholdConnectionRecord, home: String, away: String, now: Date = .now,
                isCurrent: () -> Bool, save: (VerifiedPersonalRoutes) throws -> Void) async {
        guard !busy, isCurrent() else { return }
        let operation = UUID(); generation = operation; busy = true; message = nil; lastFailure = nil
        defer { if generation == operation { busy = false } }
        do {
            let profile = try VerifiedPersonalRoutes(record: record, home: HouseholdHTTPClient.endpoint(home),
                away: HouseholdHTTPClient.endpoint(away), now: now)
            var first: HouseholdSession?
            for endpoint in [profile.home, profile.away] {
                try Task.checkCancellation()
                let session = try await read(endpoint, record.deviceSecret)
                try session.validate()
                guard generation == operation, isCurrent(), !Task.isCancelled else { return }
                guard session.identity == profile.identity, first == nil || first == session else { throw HouseholdFailure.changedIdentity }
                first = session
            }
            try save(profile)
            message = "Both connections verified. This device can recover automatically when a network becomes unavailable."
        } catch {
            guard generation == operation, isCurrent(), !Task.isCancelled else { return }
            lastFailure = error as? HouseholdFailure
            message = Self.message(error)
        }
    }

    /// Network failures permit one alternate read. Authorization, TLS and identity failures do not.
    func resolve(record: HouseholdConnectionRecord, isCurrent: () -> Bool,
                 activate: (URL) throws -> Void) async -> Bool {
        guard !busy, !editing, let profile = record.verifiedRoutes, profile.enabled,
              let identity = record.identity, isCurrent() else { return false }
        let operation = UUID(); generation = operation; busy = true; message = nil; lastFailure = nil; verifiedEndpoint = nil; verifiedSession = nil
        defer { if generation == operation { busy = false } }
        do { try profile.validate(id: record.id, endpoint: record.endpoint, token: record.deviceSecret, session: identity) }
        catch { lastFailure = error as? HouseholdFailure; message = Self.message(error); return false }
        let alternate = record.endpoint == profile.home ? profile.away : profile.home
        for (index, endpoint) in [record.endpoint, alternate].enumerated() {
            do {
                try Task.checkCancellation()
                let session = try await read(endpoint, record.deviceSecret)
                try session.validate()
                guard generation == operation, isCurrent(), !Task.isCancelled else { return false }
                guard session.identity == profile.identity else { throw HouseholdFailure.changedIdentity }
                if endpoint != record.endpoint { try activate(endpoint) }
                verifiedEndpoint = endpoint; verifiedSession = session
                message = endpoint == profile.home ? "Home connection verified." : "Away connection verified."
                return true
            } catch {
                guard generation == operation, isCurrent(), !Task.isCancelled else { return false }
                if index == 0, OwnerRouteResolver.permitsFallback(after: error) { continue }
                lastFailure = error as? HouseholdFailure
                message = Self.message(error)
                return false
            }
        }
        return false
    }

    static func message(_ error: Error) -> String {
        if error as? HouseholdFailure == .authentication || error as? HouseholdFailure == .forbidden {
            return "This personal key is no longer authorized. Reconnect your account before trying another address."
        }
        if error as? HouseholdFailure == .changedIdentity { return "The Pod or personal account changed. Review your connections before continuing." }
        if error as? HouseholdFailure == .storage { return "Secure storage could not save this connection. Your previous address is unchanged." }
        if error is PersonalRouteFailure { return PersonalRouteFailure.freshness.localizedDescription }
        if let transport = error as? URLError, [.secureConnectionFailed, .serverCertificateHasBadDate,
            .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired].contains(transport.code) {
            return "The HTTPS certificate could not be verified. Check the gateway’s secure connection."
        }
        if OwnerRouteResolver.permitsFallback(after: error) {
            return "The saved network connections could not be reached. Check home Wi-Fi or your private remote access."
        }
        return "The controller’s personal connection could not be verified. Review its status and the saved addresses."
    }
}
