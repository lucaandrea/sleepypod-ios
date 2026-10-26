import CryptoKit
import Foundation

/// Atomic, protected state prevents another screen or a reopened app from repeating an uncertain POST.
@MainActor final class ControllerUpdateJournal {
    private let directory: URL?
    private var memory: [String: ControllerUpdateAttempt] = [:]
    init(directory: URL?) { self.directory = directory }
    static func persistent() throws -> Self {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "ControllerUpdates", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return .init(directory: directory)
    }
    func read(scope: String) throws -> ControllerUpdateAttempt? {
        let key = digest(scope)
        guard let directory else { return memory[key] }
        let url = directory.appending(path: key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ControllerUpdateAttempt.self, from: Data(contentsOf: url))
    }
    func replace(_ value: ControllerUpdateAttempt?, expected: ControllerUpdateAttempt?, scope: String) throws {
        guard try read(scope: scope) == expected else {
            throw APIError.serverError(message: "Another update view changed the retained request. Reopen Updates before continuing.")
        }
        let key = digest(scope)
        guard let directory else { memory[key] = value; return }
        let url = directory.appending(path: key + ".json")
        if let value {
            try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func discardUnreadable(scope: String) throws {
        do {
            if try read(scope: scope) != nil {
                throw APIError.serverError(message: "The retained request is readable. Reopen Updates to review it.")
            }
        } catch let error as APIError { throw error }
        catch {
            guard let directory else { throw error }
            try FileManager.default.removeItem(at: directory.appending(path: digest(scope) + ".json"))
        }
    }
    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
