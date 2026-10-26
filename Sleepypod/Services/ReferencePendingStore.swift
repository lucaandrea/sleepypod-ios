import CryptoKit
import Foundation

enum ReferencePending: Codable, Equatable, Sendable {
    case commit(ReferenceCommit)
    case deletion(ReferenceDescriptor)
    var side: Side {
        switch self {
        case .commit(let request): request.input.side
        case .deletion(let descriptor): descriptor.summary.side
        }
    }
}

/// Protect original health rows and retain exact intent before sending a source mutation.
@MainActor final class ReferencePendingStore {
    private let directory: URL?
    private var memory: [String: ReferencePending] = [:]
    init(directory: URL?) { self.directory = directory }
    static func persistent() throws -> ReferencePendingStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "ReferenceRequests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return .init(directory: directory)
    }
    func read(scope: String, side: Side) throws -> ReferencePending? {
        let key = key(scope, side)
        guard let directory else { return memory[key] }
        let url = directory.appending(path: key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = try JSONDecoder().decode(ReferencePending.self, from: Data(contentsOf: url))
        guard request.side == side else { throw ReferenceTextError(message: "The retained request belongs to another side.") }
        return request
    }
    func write(_ request: ReferencePending, scope: String, side: Side) throws {
        guard request.side == side else { throw changed }
        if let current = try read(scope: scope, side: side), current != request { throw changed }
        let key = key(scope, side)
        guard let directory else { memory[key] = request; return }
        try JSONEncoder().encode(request).write(to: directory.appending(path: key + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(_ expected: ReferencePending, scope: String, side: Side) throws {
        if let current = try read(scope: scope, side: side), current != expected { throw changed }
        try erase(scope: scope, side: side)
    }
    func discardUnreadable(scope: String, side: Side) throws {
        let current: ReferencePending?
        do { current = try read(scope: scope, side: side) }
        catch { try erase(scope: scope, side: side); return }
        guard current == nil else { throw changed }
    }
    private func erase(scope: String, side: Side) throws {
        let key = key(scope, side)
        guard let directory else { memory[key] = nil; return }
        let url = directory.appending(path: key + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private var changed: ReferenceTextError { .init(message: "Another reference request is retained for this controller and side. Reopen References to inspect it.") }
    private func key(_ scope: String, _ side: Side) -> String { SHA256.hash(data: Data("\(scope)\n\(side.rawValue)".utf8)).map { String(format: "%02x", $0) }.joined() }
}
