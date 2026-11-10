import Foundation

struct PersonalIntelligenceStore {
    private let file: URL
    private let snapshots: PrivateSnapshotStore
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "PersonalIntelligence", directoryHint: .isDirectory),
         snapshots: PrivateSnapshotStore? = nil) {
        file = directory.appending(path: "history-and-reports.json")
        self.snapshots = snapshots ?? .init(directory: directory, namespace: "personal-intelligence-v1")
    }
    func read() throws -> PersonalIntelligenceArchive {
        try PersonalWorkspaceBoundary.requireLegacyAccess()
        if let saved = try snapshots.read(PersonalIntelligenceArchive.self, scope: "device-owner") { return saved }
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let legacy = try JSONDecoder().decode(PersonalIntelligenceArchive.self, from: Data(contentsOf: file))
        // Complete the protected write before removing the previous local archive.
        try write(legacy)
        return legacy
    }
    func write(_ value: PersonalIntelligenceArchive) throws {
        try PersonalWorkspaceBoundary.requireLegacyAccess()
        try snapshots.write(value, scope: "device-owner")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
