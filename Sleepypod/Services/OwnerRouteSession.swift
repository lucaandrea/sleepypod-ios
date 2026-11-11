import Foundation
import FreeSleepKit
import Observation

/// Coordinates enrollment and read-only recovery without replaying commands or changing owner identity.
@MainActor @Observable final class OwnerRouteSession {
    private(set) var profile: EnrolledOwnerRoutes?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var checkedAt: Date?
    private(set) var change = UUID()
    private(set) var editing = false
    private var generation = UUID()
    private let resolver = OwnerRouteResolver()
    private let revision: () -> [String]
    private let allowed: () -> Bool
    private let key: (String) -> String
    private let saveKey: (String, String) throws -> Void
    private let load: ([String]) throws -> EnrolledOwnerRoutes?
    private let save: (EnrolledOwnerRoutes, [String]) throws -> Void
    private let establishRevision: (String) -> Void
    private let identity: (OwnerConnectionCandidate) async throws -> UUID
    private let now: () -> Date

    var currentAddress: String { let current = revision(); return current.count == 5 ? current[1] : "" }
    func savedKey(for address: String) -> String { key(address) }

    init(revision: @escaping () -> [String] = { OwnerConnection.revision },
         allowed: @escaping () -> Bool = { !PersonalWorkspaceBoundary.isActive && APIBackend.current == .sleepypodCore },
         key: @escaping (String) -> String = UnifiedRuntime.savedKey,
         saveKey: @escaping (String, String) throws -> Void = { try UnifiedRuntime.saveConnectionKey($1, for: $0) },
         load: @escaping ([String]) throws -> EnrolledOwnerRoutes? = { try OwnerRouteProfileStore().load(revision: $0, key: UnifiedRuntime.savedKey) },
         save: @escaping (EnrolledOwnerRoutes, [String]) throws -> Void = { try OwnerRouteProfileStore().save($0, revision: $1, key: UnifiedRuntime.savedKey) },
         establishRevision: @escaping (String) -> Void = { UserDefaults.standard.set($0, forKey: "ownerConnectionRevision") },
         identity: @escaping (OwnerConnectionCandidate) async throws -> UUID = { try await ControllerIdentityClient().read($0) },
         now: @escaping () -> Date = Date.init) {
        self.revision = revision; self.allowed = allowed; self.key = key; self.saveKey = saveKey
        self.load = load; self.save = save; self.establishRevision = establishRevision; self.identity = identity; self.now = now
    }

    func invalidate() {
        generation = UUID(); resolver.invalidate(); busy = false; profile = nil; checkedAt = nil; message = nil
    }

    /// Editing owns verification until dismissal; background recovery cannot steal the form's result.
    func beginEditing() {
        invalidate(); editing = true; reload()
    }

    func endEditing() {
        invalidate(); editing = false; change = UUID()
    }

    func reload() {
        guard !busy else { return }
        profile = nil; checkedAt = nil; message = nil
        let current = revision()
        guard allowed(), current.count == 5, !current[3].isEmpty else { return }
        do { profile = try load(current) }
        catch { message = "Your saved home and away setup could not be read. Unlock this device and check again; your current connection and backup alarm are unchanged." }
    }

    /// The currently active credential cannot be replaced as a side effect of adding another route.
    func enroll(home: OwnerConnectionCandidate, away: OwnerConnectionCandidate) async -> Bool {
        guard !busy, allowed() else { return false }
        let original = revision(), operation = UUID()
        guard original.count == 5, let active = [home, away].first(where: { $0.endpoint.absoluteString == original[1] }),
              !active.token.isEmpty, key(original[1]) == active.token else {
            message = "Keep your current address and its saved key in one of these connections. Replace your main connection separately if needed."
            return false
        }
        generation = operation; busy = true; message = nil; checkedAt = nil
        defer { if generation == operation { busy = false } }
        do {
            let previous = original[3].isEmpty ? nil : try load(original)
            var enrolledRevision = original
            if enrolledRevision[3].isEmpty { enrolledRevision[3] = UUID().uuidString }
            let verified = try await OwnerRouteVerification.verify(home: home, away: away, currentAddress: original[1],
                credentialRevision: enrolledRevision[3], now: now(), isCurrent: { self.current(operation, original) }, readIdentity: identity)
            guard current(operation, original) else { return false }
            let enrolled = try EnrolledOwnerRoutes(routes: verified, currentRevision: enrolledRevision, previous: previous,
                initialIdentity: original[3].isEmpty ? original : nil)
            let alternate = active.endpoint == home.endpoint ? away : home
            try persist(enrolled, revision: enrolledRevision, alternate: alternate)
            if original[3].isEmpty { establishRevision(enrolledRevision[3]) }
            profile = enrolled; change = UUID(); checkedAt = now()
            message = "Home and away connections verified. Automatic connection is on. Your history and wake plan stay with the same controller."
            return true
        } catch {
            guard current(operation, original) else { return false }
            message = error is CancellationError ? "Connection setup was cancelled. Your saved setup is unchanged."
                : (error as? OwnerRouteCheckFailure)?.localizedDescription
                    ?? (error as? ControllerIdentityFailure)?.localizedDescription ?? OwnerConnectionEnrollment.failureMessage(error)
            return false
        }
    }

    private func persist(_ enrolled: EnrolledOwnerRoutes, revision: [String], alternate: OwnerConnectionCandidate) throws {
        let address = alternate.endpoint.absoluteString, previousKey = key(address)
        try saveKey(address, alternate.token)
        do { try save(enrolled, revision) }
        catch {
            do { try saveKey(address, previousKey) }
            catch { throw ControllerIdentityFailure.invalidProfile }
            throw error
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !busy, allowed() else { return }
        do {
            let current = revision()
            guard var enrolled = try load(current) else { throw ControllerIdentityFailure.invalidProfile }
            enrolled.routes.enabled = enabled
            try save(enrolled, current)
            profile = enrolled; checkedAt = nil; change = UUID()
            message = enabled ? "Automatic connection is on. Each address is checked before use."
                : "Automatic connection is off. Your current address, history and backup alarm are unchanged."
        } catch { message = "The automatic connection setting could not be saved. Check the setup again." }
    }

    func resolve(activate: (OwnerConnectionCandidate) throws -> Void) async {
        guard !busy, !editing, allowed() else { return }
        let original = revision(), operation = UUID()
        guard original.count == 5, !original[3].isEmpty else { return }
        generation = operation; busy = true; checkedAt = nil
        defer { if generation == operation { busy = false } }
        do {
            guard let enrolled = try load(original) else { profile = nil; return }
            profile = enrolled
            guard enrolled.routes.enabled else { return }
            let candidates = try enrolled.routes.candidates(currentAddress: original[1], revision: original[3], key: key)
            let verified = await resolver.resolve(profile: enrolled.routes, currentAddress: original[1], candidates: candidates,
                readIdentity: identity, isCurrent: { self.current(operation, original) }, activate: { candidate in
                    // Recheck encrypted metadata and credentials after the asynchronous identity read.
                    guard try self.load(original) == enrolled else { throw ControllerIdentityFailure.changedCredentials }
                    try activate(candidate)
                })
            guard generation == operation, allowed() else { return }
            guard verified || revision() == original else { profile = nil; return }
            try enrolled.validateContext(revision())
            if verified { checkedAt = now() }
            message = resolver.message
        } catch {
            guard generation == operation, allowed() else { return }
            profile = nil; message = "Automatic connection is unavailable. Unlock this device and verify the saved addresses and keys. Your current connection was not replaced."
        }
    }

    private func current(_ operation: UUID, _ original: [String]) -> Bool {
        generation == operation && allowed() && revision() == original && !Task.isCancelled
    }
}
