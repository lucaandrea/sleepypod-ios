import Foundation
import CoreFoundation

/// The receiving identity is established by authentication, never by an exported report.
public enum MorningReportScope: Equatable, Sendable {
    case owner(installationID: UUID)
    case personal(podID: UUID, householdID: UUID, accountID: UUID, sleeperID: UUID,
                  sessionRevision: Int, householdRevision: Int, assignmentRevision: Int)

    var route: String {
        switch self {
        case .owner: "api/v1/reports"
        case .personal: "api/v1/me/reports"
        }
    }
    var sleeperID: UUID? {
        if case .personal(_, _, _, let sleeperID, _, _, _) = self { return sleeperID }
        return nil
    }
    func matches(_ object: [String: Any]) -> Bool {
        func identifier(_ key: String, _ expected: UUID) -> Bool {
            (object[key] as? String).flatMap(UUID.init(uuidString:)) == expected
        }
        switch self {
        case .owner(let installationID):
            return Set(object.keys) == ["kind", "installationId"] && object["kind"] as? String == "legacy"
                && identifier("installationId", installationID)
        case .personal(let podID, let householdID, let accountID, let sleeperID,
                       let sessionRevision, let householdRevision, let assignmentRevision):
            return Set(object.keys) == ["podId", "householdId", "accountId", "sleeperId", "sessionRevision", "householdRevision", "assignmentRevision"]
                && identifier("podId", podID) && identifier("householdId", householdID)
                && identifier("accountId", accountID) && identifier("sleeperId", sleeperID)
                && sessionRevision > 0 && householdRevision > 0 && assignmentRevision > 0
                && MorningReportWire.integer(object["sessionRevision"]) == Int64(sessionRevision)
                && MorningReportWire.integer(object["householdRevision"]) == Int64(householdRevision)
                && MorningReportWire.integer(object["assignmentRevision"]) == Int64(assignmentRevision)
        }
    }
}

public struct MorningReportReceipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: UUID
    public let deleted: Bool
    public let createdAt: Int64?
    public let receivedAt: Int64
    public let updatedAt: Int64
}

public struct MorningReportSharedCopy: Sendable {
    public let receipt: MorningReportReceipt
    /// An explicit versioned display document, without credentials or raw Health samples.
    public let document: Data?
}

public enum MorningReportSharingFailure: Error, Equatable, LocalizedError {
    case authentication, forbidden, changedAccount, conflict, unavailable, invalid, uncertain
    public var errorDescription: String? {
        switch self {
        case .authentication: "The Pod rejected this connection. Reconnect before sharing the report."
        case .forbidden: "This account cannot access that report library. Open your personal account and try again."
        case .changedAccount: "Your account or Pod changed. Reopen the report before sharing it."
        case .conflict: "The shared report changed. Refresh its status before trying again."
        case .unavailable: "Report sharing is unavailable on this controller. Check its connection and software version."
        case .invalid: "The report reply could not be verified. Refresh its status before trying again."
        case .uncertain: "The connection ended before sharing could be confirmed. Check its status; the report has not been resent."
        }
    }
}

public protocol MorningReportSharingTransport: Sendable {
    func read(id: UUID) async throws -> MorningReportSharedCopy?
    func share(id: UUID, document: Data, expectedRevision: UUID?) async throws -> MorningReportSharedCopy
    func withdraw(id: UUID, expectedRevision: UUID?) async throws -> MorningReportSharedCopy
}

enum MorningReportWire {
    static let maximumTimestamp: Int64 = 253_402_300_799_999
    /// JSON booleans and fractional/out-of-range numbers are not timestamps or revisions.
    static func integer(_ value: Any?, maximum: Int64 = maximumTimestamp) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let real = number.doubleValue
        guard real.isFinite, real >= 0, real <= Double(maximum), real.rounded(.down) == real else { return nil }
        return number.int64Value
    }

    static func reply(_ data: Data, id: UUID, scope: MorningReportScope, now: Date) throws -> MorningReportSharedCopy {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "generatedAt", "scope", "receipt", "report"],
              integer(object["version"]) == 1, let generated = integer(object["generatedAt"]),
              Double(generated) <= now.timeIntervalSince1970 * 1000 + 60_000,
              let returnedScope = object["scope"] as? [String: Any], scope.matches(returnedScope),
              let receiptObject = object["receipt"] as? [String: Any],
              Set(receiptObject.keys) == ["id", "revision", "deleted", "createdAt", "receivedAt", "updatedAt"],
              let received = integer(receiptObject["receivedAt"]), let updated = integer(receiptObject["updatedAt"]),
              received <= updated, updated <= generated else { throw MorningReportSharingFailure.invalid }
        let receipt = try JSONDecoder().decode(MorningReportReceipt.self, from: JSONSerialization.data(withJSONObject: receiptObject))
        guard receipt.id == id, receipt.createdAt.map({ $0 >= 0 && $0 <= received }) ?? receipt.deleted else {
            throw MorningReportSharingFailure.invalid
        }
        if receipt.deleted {
            guard object["report"] is NSNull else { throw MorningReportSharingFailure.invalid }
            return .init(receipt: receipt, document: nil)
        }
        guard let report = object["report"] as? [String: Any],
              (report["id"] as? String).flatMap(UUID.init(uuidString:)) == id,
              let created = integer(report["createdAt"]), created == receipt.createdAt else {
            throw MorningReportSharingFailure.invalid
        }
        let document = try JSONSerialization.data(withJSONObject: ["version": 1, "report": report], options: [.sortedKeys, .withoutEscapingSlashes])
        guard document.count <= MorningReportTransfer.maximumBytes else { throw MorningReportSharingFailure.invalid }
        return .init(receipt: receipt, document: document)
    }
}
