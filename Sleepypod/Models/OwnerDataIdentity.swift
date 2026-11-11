import Foundation
import FreeSleepKit
import CryptoKit

/// Transport revisions cancel stale requests; this identity preserves data for the same verified owner.
enum OwnerDataIdentity: Equatable {
    case owner([String])
    case noOwner
    case unavailable

    var revision: [String]? {
        if case .owner(let revision) = self { return revision }
        return nil
    }

    /// An unreadable profile is not evidence that an existing phone alarm belongs to another person.
    var canReconcileOwnership: Bool { self != .unavailable }

    // Preserve existing on-disk scope encodings when enrolling routes for the first time.
    var offlineLibraryScope: String? {
        guard let revision else { return nil }
        return Self.digest(Data(revision.prefix(4).joined(separator: "|").utf8))
    }

    var phoneBackupScope: String? {
        guard let revision, let data = try? JSONEncoder().encode(revision) else { return nil }
        return Self.digest(data)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor static var current: OwnerDataIdentity {
        let revision = OwnerConnection.revision
        return resolve(revision: revision, ownerAllowed: !PersonalWorkspaceBoundary.isActive && !APIBackend.current.isDemo) {
            try OwnerRouteProfileStore().load(revision: revision, key: UnifiedRuntime.savedKey)
        }
    }

    @MainActor static func resolve(revision: [String], ownerAllowed: Bool,
                                   loadProfile: () throws -> EnrolledOwnerRoutes?) -> OwnerDataIdentity {
        guard ownerAllowed else { return .noOwner }
        guard revision.count == 5 else { return .unavailable }
        guard revision[0] == APIBackend.sleepypodCore.rawValue, !revision[3].isEmpty else { return .owner(revision) }
        do {
            guard let profile = try loadProfile() else { return .owner(revision) }
            try profile.validateContext(revision)
            return .owner(profile.originalRevision)
        } catch { return .unavailable }
    }
}
