import CryptoKit
import Foundation

enum BiometricObservationPending: Codable, Equatable, Sendable {
    case create(BiometricObservationSubmission)
    case stop(BiometricObservationRun)
    var side: Side? {
        switch self {
        case .create(let request): request.side
        case .stop(let run): run.side
        }
    }
}

/// Keep one exact pending effect per controller and side. Reads never initiate a retry.
@MainActor final class BiometricObservationPendingStore {
    private let directory: URL?
    private var memory: [String: BiometricObservationPending] = [:]
    init(directory: URL?) { self.directory = directory }
    static func persistent() throws -> BiometricObservationPendingStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "BiometricObservationRequests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return .init(directory: directory)
    }
    func read(scope: String, side: Side) throws -> BiometricObservationPending? {
        let key = key(scope, side)
        guard let directory else { return memory[key] }
        let url = directory.appending(path: key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let pending = try JSONDecoder().decode(BiometricObservationPending.self, from: Data(contentsOf: url))
        guard pending.side == side else { throw changed }; return pending
    }
    func write(_ pending: BiometricObservationPending, scope: String, side: Side) throws {
        guard pending.side == side else { throw changed }
        if let current = try read(scope: scope, side: side), current != pending { throw changed }
        let key = key(scope, side)
        guard let directory else { memory[key] = pending; return }
        try JSONEncoder().encode(pending).write(to: directory.appending(path: key + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(_ expected: BiometricObservationPending, scope: String, side: Side) throws {
        if let current = try read(scope: scope, side: side), current != expected { throw changed }
        try erase(scope: scope, side: side)
    }
    func discardUnreadable(scope: String, side: Side) throws {
        let current: BiometricObservationPending?
        do { current = try read(scope: scope, side: side) } catch { try erase(scope: scope, side: side); return }
        guard current == nil else { throw changed }
    }
    private func erase(scope: String, side: Side) throws {
        let key = key(scope, side)
        guard let directory else { memory[key] = nil; return }
        let url = directory.appending(path: key + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private var changed: ReferenceTextError { .init(message: "Another observation request is retained for this controller and side. Reopen Observations to inspect it.") }
    private func key(_ scope: String, _ side: Side) -> String { SHA256.hash(data: Data("\(scope)\n\(side.rawValue)".utf8)).map { String(format: "%02x", $0) }.joined() }
}
