import Foundation

enum PersonalQuietContract {
    static let maximumDuration: Int64 = 86_400_000
    static let observationLifetime: Int64 = 15_000
    static func instant(_ value: Int64) -> Bool { (0...253_402_300_799_000).contains(value) }
    static func keys(_ value: Any?, _ expected: Set<String>) throws {
        guard let object = value as? [String: Any], Set(object.keys) == expected else { throw HouseholdFailure.invalid }
    }
    static func decode(_ data: Data, receipt: Bool) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HouseholdFailure.invalid }
        let common: Set<String> = ["version", "generatedAt", "scope"]
        try keys(object, common.union(receipt ? ["receipt"] : ["mine", "shared"]))
        try keys(object["scope"], ["podId", "householdId", "accountId", "sleeperId", "sessionRevision", "householdRevision", "assignmentRevision"])
        if receipt {
            if !(object["receipt"] is NSNull) { try keys(object["receipt"], ["requestId", "revision", "savedAt", "until"]) }
        } else {
            try keys(object["mine"], ["revision", "until"])
            try keys(object["shared"], ["paused", "until"])
        }
    }
    static func envelope(version: Int, generatedAt: Int64, scope: PersonalHistoryScope, session: HouseholdSession) throws {
        guard version == 1, instant(generatedAt) else { throw HouseholdFailure.invalid }
        try scope.validate(for: session)
    }
}

struct PersonalQuietPage: Codable, Equatable, Sendable {
    struct Selection: Codable, Equatable, Sendable { let revision: String?; let until: Int64? }
    struct Shared: Codable, Equatable, Sendable { let paused: Bool; let until: Int64? }
    let version: Int
    let generatedAt: Int64
    let scope: PersonalHistoryScope
    let mine: Selection
    let shared: Shared
    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalQuietContract.decode(data, receipt: false)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession) throws {
        try PersonalQuietContract.envelope(version: version, generatedAt: generatedAt, scope: scope, session: session)
        guard mine.revision.map(HouseholdValidation.identifier) ?? true,
              mine.until == nil || mine.revision != nil,
              shared.paused == (shared.until != nil) else { throw HouseholdFailure.invalid }
        for until in [mine.until, shared.until].compactMap({ $0 }) {
            guard PersonalQuietContract.instant(until), until > generatedAt,
                  until - generatedAt <= PersonalQuietContract.maximumDuration else { throw HouseholdFailure.invalid }
        }
        if let until = mine.until { guard let sharedEnd = shared.until, sharedEnd >= until else { throw HouseholdFailure.invalid } }
    }
}

struct PersonalQuietReceipt: Codable, Equatable, Sendable {
    let requestId: String
    let revision: String
    let savedAt: Int64
    let until: Int64?
    func validate(generatedAt: Int64) throws {
        guard [requestId, revision].allSatisfy(HouseholdValidation.identifier),
              PersonalQuietContract.instant(savedAt), savedAt <= generatedAt else { throw HouseholdFailure.invalid }
        if let until {
            guard PersonalQuietContract.instant(until), until > savedAt,
                  until - savedAt <= PersonalQuietContract.maximumDuration else { throw HouseholdFailure.invalid }
        }
    }
}

struct PersonalQuietResult: Codable, Equatable, Sendable {
    let version: Int
    let generatedAt: Int64
    let scope: PersonalHistoryScope
    let receipt: PersonalQuietReceipt?
    static func decodeExact(_ data: Data) throws -> Self {
        try PersonalQuietContract.decode(data, receipt: true)
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func validate(for session: HouseholdSession) throws {
        try PersonalQuietContract.envelope(version: version, generatedAt: generatedAt, scope: scope, session: session)
        try receipt?.validate(generatedAt: generatedAt)
    }
}

struct PersonalQuietWrite: Encodable, Equatable, Sendable {
    let requestId: String
    let expectedSessionRevision: Int
    let expectedAssignmentRevision: Int
    let expectedRevision: String?
    let issuedAt: Int64
    let expiresAt: Int64
    let until: Int64?
    enum CodingKeys: String, CodingKey {
        case requestId, expectedSessionRevision, expectedAssignmentRevision, expectedRevision, issuedAt, expiresAt, until
    }
    func validate() throws {
        guard HouseholdValidation.identifier(requestId), HouseholdValidation.revision(expectedSessionRevision),
              HouseholdValidation.revision(expectedAssignmentRevision), expectedRevision.map(HouseholdValidation.identifier) ?? true,
              PersonalQuietContract.instant(issuedAt), PersonalQuietContract.instant(expiresAt),
              expiresAt > issuedAt, expiresAt - issuedAt <= 60_000 else { throw HouseholdFailure.invalid }
        if let until {
            guard PersonalQuietContract.instant(until), until > issuedAt,
                  until - issuedAt <= PersonalQuietContract.maximumDuration else { throw HouseholdFailure.invalid }
        }
    }
    // Explicit null ends only this person's request; omission is never a clear action.
    func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(expectedSessionRevision, forKey: .expectedSessionRevision)
        try values.encode(expectedAssignmentRevision, forKey: .expectedAssignmentRevision)
        try values.encode(expectedRevision, forKey: .expectedRevision)
        try values.encode(issuedAt, forKey: .issuedAt)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encode(until, forKey: .until)
    }
}
