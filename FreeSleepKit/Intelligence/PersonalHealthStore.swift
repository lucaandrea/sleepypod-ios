import Foundation

/// One physical Health library has one explicit personal owner on this device.
/// Consent and imported data share one atomic encrypted record, with no legacy-owner fallback.
@MainActor struct PersonalHealthStore {
    private let snapshots: PrivateSnapshotStore
    private let scope = "device-health-enrollment"

    init(snapshots: PrivateSnapshotStore = .init(namespace: "personal-health-v1")) { self.snapshots = snapshots }

    func read() throws -> PersonalHealthArchive? {
        let value = try snapshots.read(PersonalHealthArchive.self, scope: scope)
        try value?.validate()
        return value
    }

    func enroll(identity: PersonalHealthIdentity, at date: Date) throws -> PersonalHealthArchive {
        guard try read() == nil else { throw PersonalHealthFailure.anotherAccount }
        let value = PersonalHealthArchive(identity: identity, enrolledAt: date, consentVersion: 1)
        try value.validate()
        try snapshots.write(value, scope: scope)
        return value
    }

    /// Synchronous compare-and-write prevents a late import from resurrecting a deleted enrollment.
    func update(_ value: PersonalHealthArchive, expectedRevision: UUID) throws -> PersonalHealthArchive {
        guard let saved = try read(), saved.identity == value.identity, saved.revision == expectedRevision,
              value.revision == expectedRevision, value.enrolledAt == saved.enrolledAt,
              value.consentVersion == saved.consentVersion else { throw PersonalHealthFailure.changed }
        var next = value; next.revision = UUID()
        try next.validate()
        try snapshots.write(next, scope: scope)
        return next
    }

    func remove(identity: PersonalHealthIdentity, expectedRevision: UUID) throws {
        guard let saved = try read(), saved.identity == identity, saved.revision == expectedRevision else {
            throw PersonalHealthFailure.changed
        }
        try snapshots.remove(scope: scope)
    }

    func removeAll() throws { try snapshots.remove(scope: scope) }
}
