import Foundation

struct BedWidgetStore: Sendable {
    static let appGroup = "group.com.lucaandrea.freesleep.widgets"
    static let kind = "SleepypodBedStatus"
    let directory: URL?

    static var shared: Self {
        .init(directory: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup))
    }
    private var file: URL? { directory?.appendingPathComponent("bed-status.json") }

    func read(at now: Date) -> BedWidgetSnapshot? {
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8_193), data.count <= 8_192,
              let snapshot = try? JSONDecoder().decode(BedWidgetSnapshot.self, from: data),
              snapshot.isUsable(at: now) else { return nil }
        return snapshot
    }
    func save(_ snapshot: BedWidgetSnapshot, at now: Date) throws {
        guard snapshot.isUsable(at: now), let file, let directory else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 8_192 else { throw CocoaError(.fileWriteOutOfSpace) }
        #if os(iOS) || os(watchOS)
        // Bed targets can be displayed while locked; raw Health data and credentials never enter this file.
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        var excluded = file
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
    func clear() throws {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }
}
