import CryptoKit
import Foundation

/// A protected request record is committed before dispatch; unresolved requests are never discarded.
@MainActor final class NativeControlLedger {
    private let directory: URL?
    private var memory: [String: [NativeControlAttempt]] = [:]
    init(directory: URL?) { self.directory = directory }
    static func persistent() throws -> Self {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "CommandReceipts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return .init(directory: directory)
    }
    func read(scope: [String]) throws -> [NativeControlAttempt] {
        let key = try key(scope)
        guard let directory else { return memory[key] ?? [] }
        let url = directory.appending(path: key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw NativeControlFailure.invalid }
        let values = try JSONDecoder().decode([NativeControlAttempt].self, from: data)
        guard values.count <= 200, Set(values.map(\.id)).count == values.count else { throw NativeControlFailure.invalid }
        for value in values { try value.request.validate(); try value.receipt?.validate(for: value.request) }
        return values
    }
    func append(_ request: NativeControlRequest, scope: [String]) throws {
        try request.validate()
        var values = try read(scope: scope)
        guard !values.contains(where: { $0.id == request.requestId }) else { throw NativeControlFailure.invalid }
        while values.count >= 200, let index = values.firstIndex(where: { !$0.needsReview }) { values.remove(at: index) }
        guard values.count < 200 else { throw NativeControlFailure.unresolved }
        values.append(.init(request: request)); try write(values, scope: scope)
    }
    func save(_ receipt: NativeControlReceipt, scope: [String]) throws {
        var values = try read(scope: scope)
        guard let index = values.firstIndex(where: { $0.id == receipt.requestId }) else { throw NativeControlFailure.invalid }
        try receipt.validate(for: values[index].request)
        values[index].receipt = receipt; try write(values, scope: scope)
    }
    func review(_ id: UUID, scope: [String]) throws {
        var values = try read(scope: scope)
        guard let index = values.firstIndex(where: { $0.id == id }) else { throw NativeControlFailure.invalid }
        values[index].reviewedAt = .now; try write(values, scope: scope)
    }
    private func write(_ values: [NativeControlAttempt], scope: [String]) throws {
        let key = try key(scope)
        guard let directory else { memory[key] = values; return }
        try JSONEncoder().encode(values).write(to: directory.appending(path: key + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func key(_ scope: [String]) throws -> String {
        SHA256.hash(data: try JSONEncoder().encode(scope)).map { String(format: "%02x", $0) }.joined()
    }
}
