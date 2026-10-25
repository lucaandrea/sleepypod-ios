import Foundation

struct PersonalIntelligenceStore {
    private let file: URL
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "PersonalIntelligence", directoryHint: .isDirectory)) {
        file = directory.appending(path: "history-and-reports.json")
    }
    func read() throws -> PersonalIntelligenceArchive {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        return try JSONDecoder().decode(PersonalIntelligenceArchive.self, from: Data(contentsOf: file))
    }
    func write(_ value: PersonalIntelligenceArchive) throws {
        var directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtection])
    }
}
