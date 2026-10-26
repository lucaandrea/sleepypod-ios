import CryptoKit
import Foundation

enum BiometricProfilePending: Codable, Equatable, Sendable {
    case candidate(BiometricCandidateRequest, expectedHash: String)
    case activation(BiometricActivationRequest)
    var side: Side {
        switch self {
        case .candidate(let request, _): request.side
        case .activation(let request): request.side
        }
    }
    var title: String {
        switch self {
        case .candidate: "Candidate save"
        case .activation(let request): request.action.title
        }
    }
}

/// Keep the exact request across navigation/relaunch before sending any idempotent mutation.
@MainActor final class BiometricProfilePendingStore {
    private let directory: URL?
    private var memory: [String: BiometricProfilePending] = [:]
    init(directory: URL?) { self.directory = directory }
    static func persistent() throws -> BiometricProfilePendingStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "ProfileRequests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return BiometricProfilePendingStore(directory: directory)
    }
    func read(scope: String, side: Side) throws -> BiometricProfilePending? {
        let key = key(scope, side)
        guard let directory else { return memory[key] }
        let url = directory.appending(path: key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = try JSONDecoder().decode(BiometricProfilePending.self, from: Data(contentsOf: url))
        guard request.side == side else { throw APIError.serverError(message: "The retained request belongs to another side. Do not retry it.") }
        return request
    }
    func write(_ request: BiometricProfilePending, scope: String, side: Side) throws {
        guard request.side == side else { throw APIError.serverError(message: "Cannot retain a request for another side.") }
        if let retained = try read(scope: scope, side: side), retained != request { throw changedRequest }
        let key = key(scope, side)
        guard let directory else { memory[key] = request; return }
        let url = directory.appending(path: key + ".json")
        try JSONEncoder().encode(request).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    /// A late response must not erase a newer request retained by another workspace.
    func remove(_ expected: BiometricProfilePending, scope: String, side: Side) throws {
        if let retained = try read(scope: scope, side: side), retained != expected { throw changedRequest }
        try erase(scope: scope, side: side)
    }
    func discardUnreadable(scope: String, side: Side) throws {
        let retained: BiometricProfilePending?
        do { retained = try read(scope: scope, side: side) }
        catch { try erase(scope: scope, side: side); return }
        guard retained == nil else { throw changedRequest }
    }
    private func erase(scope: String, side: Side) throws {
        let key = key(scope, side)
        guard let directory else { memory[key] = nil; return }
        let url = directory.appending(path: key + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private var changedRequest: APIError { .serverError(message: "Another retained request exists for this controller and side. Reopen calibration to inspect it before continuing.") }
    private func key(_ scope: String, _ side: Side) -> String {
        SHA256.hash(data: Data("\(scope)\n\(side.rawValue)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
