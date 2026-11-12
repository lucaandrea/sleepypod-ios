#if DEBUG
import Foundation
import FreeSleepKit

/// Synthetic, offline-only contents use a separate namespace with the production Keychain implementation.
@MainActor enum PersonalOfflinePreview {
    static func make() -> HouseholdWorkspace? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--personal-offline-fixture"), arguments.indices.contains(index + 1) else { return nil }
        do {
            let mode = arguments[index + 1]
            let review = try JSONDecoder().decode(PersonalRoutineReview.self, from: fixture("personal-routines-v1", key: "readyReview"))
            var object = try dictionary(fixture("household-preparation-v1", key: "ownerSession"))
            object["podId"] = review.scope.podId; object["householdId"] = review.scope.householdId
            object["selfSleeperId"] = review.scope.sleeperId; object["sessionRevision"] = review.scope.sessionRevision
            object["assignmentRevision"] = review.scope.assignmentRevision
            object["self"] = ["displayName": "Example sleeper", "zones": ["left", "right"], "assignment": "solo"]
            var flags = object["capabilities"] as? [String: Any] ?? [:]
            flags["personalHistory"] = true; flags["personalRoutinePublication"] = true
            object["capabilities"] = flags
            let session = try JSONDecoder().decode(HouseholdSession.self, from: JSONSerialization.data(withJSONObject: object))
            let record = HouseholdConnectionRecord(id: UUID(uuidString: "99000000-0000-4000-8000-000000000001")!,
                endpoint: URL(string: "https://personal-offline-preview.invalid")!, deviceSecret: String(repeating: "A", count: 43), identity: session)
            let connection = PersonalBedConnection(id: record.id, endpoint: record.endpoint, token: record.deviceSecret, session: session)
            let folder = URL.applicationSupportDirectory.appending(path: "PersonalOfflineFixture")
            let snapshots = PrivateSnapshotStore(directory: folder, namespace: "personal-offline-ui-fixture")
            let store = PersonalOfflineLibraryStore(snapshots: snapshots)
            if mode != "reopen" {
                try store.remove(connection: connection)
                if mode != "empty" {
                    let instant = Int64(Date().timeIntervalSince1970 * 1_000) - 3_600_000
                    try store.save(review, connection: connection, receivedAt: instant - 60_000)
                    for kind in PersonalHistoryQuery.Kind.allCases { try store.save(page(session, kind: kind, at: instant), appending: false, connection: connection, receivedAt: instant) }
                }
            }
            let selectedStore = mode == "locked" ? PersonalOfflineLibraryStore(snapshots: .init(directory: folder, namespace: "personal-offline-ui-fixture", encryptionKey: { throw HouseholdFailure.storage })) : store
            let vault = PersonalHistoryPreviewVault(state: .init(connections: [record], selected: record.id))
            let defaults = UserDefaults(suiteName: "personal-offline-ui-fixture")!
            defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
            let server = PersonalOfflinePreviewServer()
            return HouseholdWorkspace(vault: vault, offlineStore: selectedStore, defaults: defaults, client: { _ in server }, capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in "" })
        } catch { return nil }
    }
    private static func page(_ session: HouseholdSession, kind: PersonalHistoryQuery.Kind, at instant: Int64) -> PersonalHistoryPage {
        let payload: PersonalHistoryPayload = switch kind {
        case .presence: .presence(seconds: 25_200, exits: 2)
        case .vitals: .vitals(heartRate: 61, breathingRate: nil, hrv: 28, metric: .windowVariability)
        case .movement: .movement(total: 42)
        }
        let query = PersonalHistoryQuery(startsAt: instant - 30 * 86_400_000, endsAt: instant, kind: kind, limit: 30)
        let suffix = kind == .presence ? "001" : kind == .vitals ? "002" : "003"
        let record = PersonalHistoryRecord(id: "10000000-0000-4000-8000-000000000" + suffix, sleeperId: session.selfSleeperId,
            startsAt: instant - 86_400_000, endsAt: instant - 57_600_000, recordedSide: .left, payload: payload,
            attribution: .init(epochId: "20000000-0000-4000-8000-000000000001", mode: .soloMerged, basis: .arrangement,
                               identity: "reviewed_arrangement_not_biometric_identification"))
        return .init(version: 1, scope: .init(podId: session.podId, householdId: session.householdId, accountId: session.accountId,
            sleeperId: session.selfSleeperId, sessionRevision: session.sessionRevision, householdRevision: session.householdRevision,
            assignmentRevision: session.assignmentRevision), attributionRevision: 2, generatedAt: instant, source: "pod",
            interpretation: "recordings_not_confirmed_sleep", query: query, intervalSelection: "overlap_full_records", records: [record], nextCursor: nil)
    }
    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HouseholdFailure.invalid }; return value
    }
    private static func fixture(_ file: String, key: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: file, withExtension: "json"), let value = try dictionary(Data(contentsOf: url))[key] else { throw HouseholdFailure.invalid }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

private actor PersonalOfflinePreviewServer: HouseholdTransport {
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        guard method == "GET", path == "household/session" else { throw HouseholdFailure.forbidden }
        throw HouseholdFailure.uncertain
    }
}
#endif
