#if DEBUG
import Foundation

actor PersonalHistoryPreviewServer: PersonalHistoryTransport, HouseholdTransport {
    let account: HouseholdSession
    let mode: String
    private var saved: [String: PersonalHistoryRecord] = [:]
    init(account: HouseholdSession, mode: String) { self.account = account; self.mode = mode }
    func session() async throws -> HouseholdSession { account }
    private var scope: PersonalHistoryScope {
        .init(podId: account.podId, householdId: account.householdId, accountId: account.accountId, sleeperId: account.selfSleeperId,
              sessionRevision: account.sessionRevision, householdRevision: account.householdRevision, assignmentRevision: account.assignmentRevision)
    }
    func page(_ query: PersonalHistoryQuery, cursor: String?) async throws -> PersonalHistoryPage {
        if mode == "stale", cursor != nil { throw HouseholdFailure.conflict }
        let count = mode == "empty" ? 0 : cursor == nil ? query.limit : 1
        let records = (0..<count).map { index -> PersonalHistoryRecord in
            let offset = cursor == nil ? index + 1 : 99
            let start = cursor == nil ? query.endsAt - Int64(offset) * 86_400_000 : query.startsAt - 3_600_000
            let payload: PersonalHistoryPayload = switch query.kind {
            case .presence: .presence(seconds: 25_200, exits: 2)
            case .vitals: .vitals(heartRate: 61, breathingRate: nil, hrv: 28, metric: .windowVariability)
            case .movement: .movement(total: 42)
            }
            return .init(id: String(format: "10000000-0000-4000-8000-%012d", offset), sleeperId: account.selfSleeperId,
                         startsAt: start, endsAt: start + 28_800_000, recordedSide: index.isMultiple(of: 2) ? .left : .right, payload: payload,
                         attribution: .init(epochId: "20000000-0000-4000-8000-000000000001", mode: .soloMerged, basis: .arrangement,
                                            identity: "reviewed_arrangement_not_biometric_identification"))
        }.filter { query.overlaps($0) }
        for record in records { saved[record.id] = record }
        return .init(version: 1, scope: scope, attributionRevision: 2, generatedAt: query.endsAt, source: "pod", interpretation: "recordings_not_confirmed_sleep",
                     query: query, intervalSelection: "overlap_full_records", records: records,
                     nextCursor: cursor == nil && records.count == query.limit ? "opaque-preview-cursor" : nil)
    }
    func detail(_ id: UUID) async throws -> PersonalHistoryDetail {
        guard let record = saved[id.uuidString.lowercased()] else { throw HouseholdFailure.unavailable }
        return .init(version: 1, scope: scope, attributionRevision: 2, generatedAt: Int64(Date().timeIntervalSince1970 * 1_000),
                     source: "pod", interpretation: "recordings_not_confirmed_sleep", record: record)
    }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        guard method == "GET" else { throw HouseholdFailure.forbidden }
        switch path {
        case "household/session": return try JSONEncoder().encode(account)
        case "me/preferences": return try JSONEncoder().encode(HouseholdPreferencesResponse(sleeperId: account.selfSleeperId, revision: 1, preferences: .blank))
        case "me/routines": return try JSONEncoder().encode(HouseholdRoutinesResponse(sleeperId: account.selfSleeperId, revision: 1, status: "draft_only", routines: []))
        case "household/devices": return Data(#"{"devices":[{"id":"00000000-0000-4000-8000-000000000008","name":"Preview phone","createdAt":"2026-10-29T20:00:00Z","current":true}]}"#.utf8)
        case "household/invitations": return Data(#"{"invitations":[]}"#.utf8)
        default: throw HouseholdFailure.unavailable
        }
    }
}
#endif
