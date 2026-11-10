import CryptoKit
import XCTest
@testable import FreeSleepKit

final class PrivateSnapshotTests: XCTestCase {
    func testEncryptedRoundTripAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = PrivateSnapshotStore(directory: directory, namespace: "test", encryptionKey: { key })
        try store.write(["private": "private sleep details"], scope: "luca")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(try Data(contentsOf: files[0]).contains(Data("private sleep details".utf8)))
        XCTAssertEqual(try store.read([String: String].self, scope: "luca"), ["private": "private sleep details"])
        XCTAssertNil(try store.read([String: String].self, scope: "marissa"))
        try store.remove(scope: "luca")
        XCTAssertNil(try store.read([String: String].self, scope: "luca"))
    }

    func testMovingCiphertextBetweenAccountsFailsAuthentication() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = PrivateSnapshotStore(directory: directory, namespace: "test", encryptionKey: { key })
        try store.write("Luca’s records", scope: "luca")
        let first = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let ciphertext = try Data(contentsOf: first)
        try store.write("Marissa’s records", scope: "marissa")
        let other = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0 != first })
        try ciphertext.write(to: other)
        XCTAssertThrowsError(try store.read(String.self, scope: "marissa"))
        XCTAssertEqual(try store.read(String.self, scope: "luca"), "Luca’s records")
    }

    func testUnavailableKeyDoesNotOverwriteExistingSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = PrivateSnapshotStore(directory: directory, namespace: "test", encryptionKey: { key })
        try store.write("previous", scope: "luca")
        let locked = PrivateSnapshotStore(directory: directory, namespace: "test", encryptionKey: { throw CocoaError(.fileReadNoPermission) })
        XCTAssertThrowsError(try locked.write("replacement", scope: "luca"))
        XCTAssertEqual(try store.read(String.self, scope: "luca"), "previous")
    }

    func testModifiedCiphertextCannotBeRead() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SymmetricKey(size: .bits256)
        let store = PrivateSnapshotStore(directory: directory, namespace: "test", encryptionKey: { key })
        try store.write("confirmed schedule", scope: "luca")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: file)
        XCTAssertThrowsError(try store.read(String.self, scope: "luca"))
    }

    func testReportArchiveMigratesWithoutLosingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appending(path: "history-and-reports.json")
        let key = SymmetricKey(size: .bits256)
        let snapshots = PrivateSnapshotStore(directory: directory, namespace: "migration", encryptionKey: { key })
        let store = PersonalIntelligenceStore(directory: directory, snapshots: snapshots)
        var archive = PersonalIntelligenceArchive()
        archive.reports = [.init(id: UUID(), createdAt: Date(), provider: .apple, model: "Local", source: "Synthetic",
                                 facts: [], text: "Preserve this report and its timestamp.")]
        try JSONEncoder().encode(archive).write(to: legacy)
        try PersonalWorkspaceBoundary.$suppliedActive.withValue(false) {
            let restored = try store.read()
            XCTAssertEqual(restored.reports, archive.reports)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
            XCTAssertEqual(try store.read().reports, restored.reports)
        }
        try PersonalWorkspaceBoundary.$suppliedActive.withValue(true) {
            XCTAssertThrowsError(try store.read())
        }
    }

    func testFailedReportEncryptionRetainsLegacyArchiveForRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appending(path: "history-and-reports.json")
        let original = try JSONEncoder().encode(PersonalIntelligenceArchive())
        try original.write(to: legacy)
        let locked = PrivateSnapshotStore(directory: directory, namespace: "migration", encryptionKey: { throw CocoaError(.fileReadNoPermission) })
        let store = PersonalIntelligenceStore(directory: directory, snapshots: locked)
        try PersonalWorkspaceBoundary.$suppliedActive.withValue(false) {
            XCTAssertThrowsError(try store.read())
            XCTAssertEqual(try Data(contentsOf: legacy), original)
        }
    }
}
