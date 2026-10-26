import CryptoKit
import Foundation

enum BiometricBacktestPending: Codable, Equatable, Sendable {
    struct DatasetIdentity: Codable, Equatable, Sendable {
        let id: String
        let contentHash: String
        let side: Side
        func matches(_ dataset: BiometricDataset) -> Bool { dataset.validIdentity && dataset.id == id && dataset.contentHash == contentHash && dataset.side == side }
    }
    case dataset(BiometricDatasetRequest)
    case waveform(side: Side, request: WaveformDatasetRequest)
    case releaseDataset(DatasetIdentity)
    var side: Side {
        switch self {
        case .dataset(let input): input.side
        case .waveform(let side, _): side
        case .releaseDataset(let input): input.side
        }
    }
}

/// Keep one exact pending effect per controller and side. Reads never initiate a retry.
@MainActor final class BiometricBacktestPendingStore {
    private let directory: URL?
    private var memory: [String: BiometricBacktestPending] = [:]
    init(directory: URL?) { self.directory = directory }
    static func persistent() throws -> BiometricBacktestPendingStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "BiometricBacktestRequests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return .init(directory: directory)
    }
    func read(scope: String, side: Side) throws -> BiometricBacktestPending? {
        let key = key(scope, side)
        guard let directory else { return memory[key] }
        let url = directory.appending(path: key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let pending = try JSONDecoder().decode(BiometricBacktestPending.self, from: Data(contentsOf: url))
        guard pending.side == side else { throw changed }; return pending
    }
    func write(_ pending: BiometricBacktestPending, scope: String, side: Side) throws {
        guard pending.side == side else { throw changed }
        if let current = try read(scope: scope, side: side), current != pending { throw changed }
        let key = key(scope, side)
        guard let directory else { memory[key] = pending; return }
        try JSONEncoder().encode(pending).write(to: directory.appending(path: key + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func remove(_ expected: BiometricBacktestPending, scope: String, side: Side) throws {
        if let current = try read(scope: scope, side: side), current != expected { throw changed }
        try erase(scope: scope, side: side)
    }
    func discardUnreadable(scope: String, side: Side) throws {
        let current: BiometricBacktestPending?
        do { current = try read(scope: scope, side: side) } catch { try erase(scope: scope, side: side); return }
        guard current == nil else { throw changed }
    }
    private func erase(scope: String, side: Side) throws {
        let key = key(scope, side)
        guard let directory else { memory[key] = nil; return }
        let url = directory.appending(path: key + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private var changed: ReferenceTextError { .init(message: "Another backtest request is retained for this controller and side. Reopen Backtests to inspect it.") }
    private func key(_ scope: String, _ side: Side) -> String { SHA256.hash(data: Data("\(scope)\n\(side.rawValue)".utf8)).map { String(format: "%02x", $0) }.joined() }
}
