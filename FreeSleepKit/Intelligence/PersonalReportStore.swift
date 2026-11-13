import Foundation

/// Synchronous compare-and-write prevents late replies from resurrecting deleted reports.
@MainActor struct PersonalReportStore {
    static let directory = URL.applicationSupportDirectory.appending(path: "PersonalAccountReports", directoryHint: .isDirectory)
    private let snapshots: PrivateSnapshotStore
    private let now: () -> Date

    init(snapshots: PrivateSnapshotStore? = nil, now: @escaping () -> Date = { .now }) {
        self.snapshots = snapshots ?? .init(directory: Self.directory, namespace: "personal-account-reports-v1")
        self.now = now
    }

    func read(_ identity: PersonalHealthIdentity) throws -> PersonalReportArchive? {
        guard let saved = try snapshots.read(PersonalReportArchive.self, scope: identity.reportScope) else { return nil }
        guard saved.identity == identity else { throw PersonalReportFailure.invalid }
        try saved.validate(now: now())
        return saved
    }

    func open(_ identity: PersonalHealthIdentity) throws -> PersonalReportArchive {
        if let saved = try read(identity) { return saved }
        let saved = PersonalReportArchive(identity: identity)
        try saved.validate(now: now())
        try snapshots.write(saved, scope: identity.reportScope)
        return saved
    }

    func update(_ value: PersonalReportArchive, expectedRevision: UUID) throws -> PersonalReportArchive {
        guard let saved = try read(value.identity), saved.revision == expectedRevision,
              value.revision == expectedRevision else { throw PersonalReportFailure.changed }
        var next = value; next.revision = UUID()
        try next.validate(now: now())
        try snapshots.write(next, scope: value.identity.reportScope)
        return next
    }

    func remove(_ identity: PersonalHealthIdentity) throws { try snapshots.remove(scope: identity.reportScope) }

    /// The explicit all-personal-data erasure owns this dedicated directory, not the owner's archive.
    static func eraseAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
