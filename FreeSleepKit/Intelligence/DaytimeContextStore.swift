import Foundation

struct DaytimeContextStore {
    private let snapshots: PrivateSnapshotStore
    init(snapshots: PrivateSnapshotStore = .init(namespace: "daytime-context-v1")) { self.snapshots = snapshots }

    func read(scope: String) throws -> DaytimeContextArchive {
        let archive = try snapshots.read(DaytimeContextArchive.self, scope: scope) ?? .init()
        try validate(archive)
        return archive
    }
    func write(_ archive: DaytimeContextArchive, scope: String) throws {
        try validate(archive)
        try snapshots.write(archive, scope: scope)
    }
    func remove(scope: String) throws { try snapshots.remove(scope: scope) }

    private func validate(_ archive: DaytimeContextArchive) throws {
        guard archive.version == 1, archive.enabled || archive.snapshot == nil else { throw DaytimeContextError.invalidSnapshot }
        try archive.snapshot?.validate()
    }
}
