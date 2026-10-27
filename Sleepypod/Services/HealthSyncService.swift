import BackgroundTasks
import Foundation
import HealthKit
import Observation
import UIKit

@MainActor
protocol HealthSyncStore {
    var available: Bool { get }
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus
    func authorize(write: Set<HKSampleType>, read: Set<HKObjectType>) async throws
    func save(_ samples: [HKSample]) async throws
    func delete(types: Set<HKSampleType>, deviceID: String, start: Date, end: Date, olderThan version: Int?) async throws
    func deleteAll(types: Set<HKSampleType>, deviceID: String, olderThan version: Int) async throws
    func sleepSamples(start: Date, end: Date) async throws -> [HKCategorySample]
    func quantitySamples(_ type: HKQuantityTypeIdentifier, start: Date, end: Date) async throws -> [HKQuantitySample]
}

@MainActor
final class SystemHealthSyncStore: HealthSyncStore {
    private let store = HKHealthStore()
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus { store.authorizationStatus(for: type) }
    func authorize(write: Set<HKSampleType>, read: Set<HKObjectType>) async throws {
        try await store.requestAuthorization(toShare: write, read: read)
    }
    func save(_ samples: [HKSample]) async throws { try await store.save(samples) }
    // HealthKit only lets an app delete its own samples; the device match keeps other pods and sides out.
    func delete(types: Set<HKSampleType>, deviceID: String, start: Date, end: Date, olderThan version: Int?) async throws {
        var predicates = [
            HKQuery.predicateForObjects(from: .default()),
            HKQuery.predicateForObjects(withDeviceProperty: HKDevicePropertyKeyLocalIdentifier, allowedValues: [deviceID]),
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        ]
        if let version {
            predicates.append(HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncVersion,
                                                          operatorType: .lessThan, value: version))
        }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        for type in types {
            _ = try await store.deleteObjects(of: type, predicate: predicate)
        }
    }
    // Only the rebuilt Pod and side, including nights older than the replay window.
    func deleteAll(types: Set<HKSampleType>, deviceID: String, olderThan version: Int) async throws {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: .default()),
            HKQuery.predicateForObjects(withDeviceProperty: HKDevicePropertyKeyLocalIdentifier, allowedValues: [deviceID]),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncVersion, operatorType: .lessThan, value: version)
        ])
        for type in types {
            _ = try await store.deleteObjects(of: type, predicate: predicate)
        }
    }
    func sleepSamples(start: Date, end: Date) async throws -> [HKCategorySample] {
        try await HealthSyncService.querySamples(store: store, type: HKCategoryType(.sleepAnalysis), start: start, end: end)
    }
    func quantitySamples(_ type: HKQuantityTypeIdentifier, start: Date, end: Date) async throws -> [HKQuantitySample] {
        try await HealthSyncService.querySamples(store: store, type: HKQuantityType(type), start: start, end: end)
    }
}

@MainActor
@Observable
final class HealthSyncService {
    struct Preferences: Codable, Equatable {
        var presence = true
        var sleep = true
        var heartRate = true
        var hrv = true
        var respiration = true
        var readSleep = true
        var readVitals = true
        var signature: String { "\(presence)-\(sleep)-\(heartRate)-\(hrv)-\(respiration)" }

        init() {}
        // Keys added after a build shipped decode as their defaults rather than resetting every preference.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sleep = try c.decodeIfPresent(Bool.self, forKey: .sleep) ?? true
            presence = try c.decodeIfPresent(Bool.self, forKey: .presence) ?? sleep
            heartRate = try c.decodeIfPresent(Bool.self, forKey: .heartRate) ?? true
            hrv = try c.decodeIfPresent(Bool.self, forKey: .hrv) ?? true
            respiration = try c.decodeIfPresent(Bool.self, forKey: .respiration) ?? true
            readSleep = try c.decodeIfPresent(Bool.self, forKey: .readSleep) ?? true
            readVitals = try c.decodeIfPresent(Bool.self, forKey: .readVitals) ?? true
        }
    }
    struct Receipt: Codable {
        let date: Date
        let signature: String
        let closedAt: Date
        let enteredAt: Date?
    }
    var preferences: Preferences {
        didSet { persistence.set(try? JSONEncoder().encode(preferences), forKey: "healthSyncPreferences") }
    }
    var enabled: Bool {
        didSet { persistence.set(enabled, forKey: "healthSyncEnabled") }
    }
    private(set) var receipts: [String: Receipt]
    private(set) var failures: [String: String] = [:]
    private(set) var isSyncing = false
    private(set) var lastSyncSampleCount = 0
    private let ownerRevision: @MainActor () -> [String]
    private(set) var rebuildProgress: (done: Int, total: Int)?
    var authorizationError: String?
    /// Personal stage models; when one is active, synced nights are staged by it and its version is in the receipt.
    weak var stageModels: StageModelStore?
    /// The last HealthKit read failure, so the Watch page can say why it is empty instead of showing a generic message.
    private(set) var readError: String?
    private let store: any HealthSyncStore
    private let persistence: UserDefaults
    @ObservationIgnored private var rebuiltKeys = Set<String>()

    init(store: any HealthSyncStore = SystemHealthSyncStore(), defaults: UserDefaults = .standard,
         ownerRevision: @escaping @MainActor () -> [String] = { OwnerConnection.revision }) {
        self.ownerRevision = ownerRevision
        self.store = store
        persistence = defaults
        preferences = defaults.data(forKey: "healthSyncPreferences").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        receipts = defaults.data(forKey: "healthSyncReceipts").flatMap { try? JSONDecoder().decode([String: Receipt].self, from: $0) } ?? [:]
        enabled = defaults.bool(forKey: "healthSyncEnabled")
    }

    static let allWriteTypes: [HKSampleType] = [HKCategoryType(.sleepAnalysis), HKQuantityType(.heartRate),
                                                HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.respiratoryRate)]

    var writeTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = []
        if preferences.presence || preferences.sleep { types.insert(HKCategoryType(.sleepAnalysis)) }
        if preferences.heartRate { types.insert(HKQuantityType(.heartRate)) }
        if preferences.hrv { types.insert(HKQuantityType(.heartRateVariabilitySDNN)) }
        if preferences.respiration { types.insert(HKQuantityType(.respiratoryRate)) }
        return types
    }

    static let vitalsReadTypes: [HKQuantityTypeIdentifier] = [.heartRate, .heartRateVariabilitySDNN, .respiratoryRate]

    var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if preferences.readSleep { types.insert(HKCategoryType(.sleepAnalysis)) }
        if preferences.readVitals { types.formUnion(Self.vitalsReadTypes.map { HKQuantityType($0) }) }
        return types
    }

    var hasWriteAuthorization: Bool {
        enabled && writeTypes.contains { store.authorizationStatus(for: $0) == .sharingAuthorized }
    }

    /// The user refused every write type on the Health sheet; iOS will not show it again.
    var authorizationDenied: Bool {
        store.available && !writeTypes.isEmpty && writeTypes.allSatisfy { store.authorizationStatus(for: $0) == .sharingDenied }
    }

    func requestAuthorization() async -> Bool {
        guard store.available else {
            authorizationError = "Apple Health is unavailable on this device."
            Log.health.info("HealthKit is unavailable on this device")
            return false
        }
        do {
            try await store.authorize(write: writeTypes, read: readTypes)
            // Completing the sheet does not prove access was granted. Each write is checked separately.
            enabled = true
            authorizationError = nil
            return true
        } catch {
            authorizationError = APIError.message(for: error)
            Log.health.error("Health authorization failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    static func recordKey(podID: String, record: SleepRecord) -> String { "\(podID)-\(record.side)-\(record.id)" }
    static func deviceID(podID: String, record: SleepRecord) -> String { "\(podID)-\(record.side)" }

    /// Bump when the samples written for a night change, so every synced night is rewritten once.
    /// v3: separately consented, disjoint reported presence; explicit sample provenance.
    static let syncVersion = 3
    static func receiptSignature(_ preferences: Preferences, model: String? = nil) -> String {
        "v\(syncVersion)-a\(SleepAnalyzer.version)-m\(model ?? "rules")-\(preferences.signature)"
    }
    func receiptSignature(_ preferences: Preferences) -> String {
        Self.receiptSignature(preferences, model: preferences.sleep ? stageModels?.activeVersion : nil)
    }

    /// The pod force-closes a session after 16 h (MAX_SESSION_S in sleep-detector); those are stuck presence, not sleep.
    static let maxSessionDuration: TimeInterval = 16 * 3600
    static let minSessionDuration: TimeInterval = 20 * 60
    static func isSyncable(_ record: SleepRecord) -> Bool {
        let duration = record.leftBedDate.timeIntervalSince(record.enteredBedDate)
        return duration >= minSessionDuration && duration < maxSessionDuration
    }

    func receipt(podID: String, record: SleepRecord) -> Receipt? {
        guard enabled, !writeTypes.isEmpty,
              writeTypes.allSatisfy({ store.authorizationStatus(for: $0) == .sharingAuthorized }),
              let receipt = receipts[Self.recordKey(podID: podID, record: record)],
              receipt.signature == receiptSignature(preferences), receipt.closedAt == record.leftBedDate, receipt.enteredAt == record.enteredBedDate else { return nil }
        return receipt
    }

    /// BGTaskScheduler identifier; must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    nonisolated static let backgroundTaskID = "com.jonathanng.sleepypod.health-sync"

    /// Ask iOS to wake the app later to sync finished nights. iOS picks the actual time,
    /// usually around when the phone is in use, so this is a floor, not a schedule.
    nonisolated static func scheduleBackgroundSync(after interval: TimeInterval = 60 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.health.error("Couldn't schedule background Health sync: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Background refresh entry point. Rebuilds the pod and side from saved settings, since
    /// no UI is running. Skips while the phone is locked: Health data is encrypted then and
    /// writes fail, so the next wake-up retries instead of recording a failure.
    func syncInBackground() async {
        guard enabled, UIApplication.shared.isProtectedDataAvailable else { return }
        guard let source = Self.linkedSource() else { return }
        await syncRecent(api: source.api, podID: source.podID, side: source.side, demo: false)
        Log.health.info("Background Health sync finished")
    }

    /// Freeze the endpoint and linked side before fetching any records. Preserve existing identity aliases.
    static func linkedSource() -> (api: any SleepypodProtocol, podID: String, side: Side)? {
        let backend = APIBackend.current, address = SettingsManager.healthAddress
        guard !backend.isDemo, !address.isEmpty else { return nil }
        let side = linkedSide()
        let api: any SleepypodProtocol
        if backend == .sleepypodCore {
            guard let endpoint = OwnerConnection.endpoint else { return nil }
            api = SleepypodCoreClient(baseURL: endpoint)
        } else { api = backend.createClient() }
        return (api, SettingsManager.registerPodIdentity(address: address), side)
    }

    static func linkedSide(defaults: UserDefaults = .standard) -> Side {
        Side(rawValue: defaults.string(forKey: "userDefaultSide") ?? defaults.string(forKey: "bedSide") ?? "left") ?? .left
    }

    func syncLinkedThirtyDays() async throws -> Int {
        guard let source = Self.linkedSource() else { throw APIError.noBaseURL }
        return try await syncThirtyDays(api: source.api, podID: source.podID, side: source.side, demo: false)
    }

    static func frozenClient() -> any SleepypodProtocol {
        if APIBackend.current == .sleepypodCore, let endpoint = OwnerConnection.endpoint { return SleepypodCoreClient(baseURL: endpoint) }
        return APIBackend.current.createClient()
    }

    static let recentDays = 7
    static let rebuildDays = 90

    func syncRecent(api: SleepypodProtocol, podID: String, side: Side, demo: Bool) async {
        guard enabled, !demo, !isSyncing, !podID.isEmpty, store.available, !writeTypes.isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }
        _ = await sync(api: api, podID: podID, side: side, days: Self.recentDays)
    }

    /// The Shortcut uses the same writer and consent as the app, with an explicit thirty-day window.
    func syncThirtyDays(api: SleepypodProtocol, podID: String, side: Side, demo: Bool) async throws -> Int {
        guard !demo, enabled, store.available, !writeTypes.isEmpty else {
            throw APIError.serverError(message: "Connect your Pod and enable the desired Apple Health write types in Settings first.")
        }
        guard !isSyncing else { throw APIError.serverError(message: "A Health sync is already running. Let it finish before starting another.") }
        guard !podID.isEmpty, writeTypes.allSatisfy({ store.authorizationStatus(for: $0) == .sharingAuthorized }) else {
            throw APIError.serverError(message: "Select your linked Pod side and allow the selected write types in Apple Health.")
        }
        try Task.checkCancellation()
        isSyncing = true; defer { isSyncing = false }
        let context = syncContext()
        let complete = await sync(api: api, podID: podID, side: side, days: 30)
        try Task.checkCancellation()
        guard isCurrent(context) else { throw APIError.serverError(message: "Your connection or Health choices changed. Sync stopped; review the current linked side before continuing.") }
        guard complete else {
            throw APIError.serverError(message: "Health sync is incomplete. Saved \(lastSyncSampleCount) \(lastSyncSampleCount == 1 ? "sample" : "samples"); open Apple Health settings in the app to review remaining errors.")
        }
        return lastSyncSampleCount
    }

    /// Rewrites this Pod/side before removing its older samples. Incomplete analysis or writes
    /// keep the old data; other Pods and sides are outside the cleanup scope.
    func rebuild(api: SleepypodProtocol, podID: String, side: Side, demo: Bool) async -> Bool {
        guard enabled, !demo, !isSyncing, !podID.isEmpty, store.available, !writeTypes.isEmpty else { return false }
        isSyncing = true
        rebuildProgress = (0, 0)
        defer { isSyncing = false; rebuildProgress = nil; rebuiltKeys.removeAll() }
        let version = nextWriteVersion()
        let context = syncContext()
        let deviceID = "\(podID)-\(side.rawValue)"
        let keyPrefix = deviceID + "-"
        failures = failures.filter { !$0.key.hasPrefix(keyPrefix) }
        rebuiltKeys.removeAll()
        guard await sync(api: api, podID: podID, side: side, days: Self.rebuildDays, forceRewrite: true), isCurrent(context) else { return false }
        // Types switched off since an earlier sync may still hold samples; only granted types can be deleted.
        let types = Set(Self.allWriteTypes.filter { store.authorizationStatus(for: $0) == .sharingAuthorized })
        do {
            try await store.deleteAll(types: types, deviceID: deviceID, olderThan: version)
            guard isCurrent(context) else { return false }
            receipts = receipts.filter { !$0.key.hasPrefix(keyPrefix) || rebuiltKeys.contains($0.key) }
            persistence.set(try JSONEncoder().encode(receipts), forKey: "healthSyncReceipts")
            Log.health.info("Rebuilt Health data")
            return true
        } catch {
            guard isCurrent(context), !Self.isCancellation(error) else { return false }
            authorizationError = APIError.message(for: error)
            Log.health.error("Health rebuild cleanup failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The core returns at most 30 records per request by default, so long windows are fetched a week at a time,
    /// and a week that hits the cap (fragmented nights) is fetched again a day at a time.
    nonisolated static let recordsPageLimit = 30
    static func sleepRecords(api: SleepypodProtocol, side: Side, start: Date, end: Date, chunk: TimeInterval = 7 * 86400) async throws -> [SleepRecord] {
        // Core already uses a bounded, recursively split 100-row range loader.
        if api is SleepypodCoreClient { return try await api.getSleepRecords(side: side, start: start, end: end) }
        var seen = Set<Int>()
        var records: [SleepRecord] = []
        var chunkStart = start
        while chunkStart < end {
            let chunkEnd = min(end, chunkStart.addingTimeInterval(chunk))
            var batch = try await api.getSleepRecords(side: side, start: chunkStart, end: chunkEnd)
            if batch.count >= recordsPageLimit {
                if chunk > 86400 {
                    batch = try await sleepRecords(api: api, side: side, start: chunkStart, end: chunkEnd, chunk: 86400)
                } else {
                    batch = try await MetricRangeLoader.load(start: chunkStart, end: chunkEnd, limit: recordsPageLimit) { lower, upper in
                        try await api.getSleepRecords(side: side, start: lower, end: upper)
                    }
                }
            }
            for record in batch where seen.insert(record.id).inserted {
                records.append(record)
            }
            chunkStart = chunkEnd
        }
        return records
    }

    /// Returns false if the sync stopped early or any night failed to write, so a rebuild knows not to sweep.
    private func sync(api: SleepypodProtocol, podID: String, side: Side, days: Int, forceRewrite: Bool = false) async -> Bool {
        let requestedPreferences = preferences, context = syncContext()
        lastSyncSampleCount = 0; authorizationError = nil
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        var complete = true
        do {
            let fetched = try await Self.sleepRecords(api: api, side: side, start: start, end: end)
            guard isCurrent(context) else { return false }
            guard fetched.allSatisfy({ $0.side == side.rawValue && $0.enteredBedDate.timeIntervalSince1970 > 0 && ($0.completedAt == nil || $0.leftBedDate > $0.enteredBedDate) }) else {
                throw APIError.serverError(message: "The controller returned an invalid or different side's sleep record. Existing Health data was kept.")
            }
            let records = fetched.filter { $0.completedAt != nil && $0.leftBedDate <= end }
            if rebuildProgress != nil { rebuildProgress = (0, records.count) }
            for record in records {
                if let progress = rebuildProgress { rebuildProgress = (progress.done + 1, progress.total) }
                let key = Self.recordKey(podID: podID, record: record)
                let syncable = Self.isSyncable(record)
                // An excluded record with a receipt was written by an earlier version; only those need cleanup.
                guard syncable ? (forceRewrite || receipt(podID: podID, record: record) == nil) : receipts[key] != nil else { continue }
                do {
                    guard isCurrent(context) else { return false }
                    guard writeTypes.allSatisfy({ store.authorizationStatus(for: $0) == .sharingAuthorized }) else {
                        failures[key] = "Allow the selected write types in Apple Health."
                        complete = false
                        continue
                    }
                    let deviceID = Self.deviceID(podID: podID, record: record)
                    // Cover the interval an earlier sync wrote too, in case the pod has since moved the record's bounds.
                    let previous = receipts[key]
                    let clearStart = min(record.enteredBedDate, previous?.enteredAt ?? record.enteredBedDate)
                    let clearEnd = max(record.leftBedDate, previous?.closedAt ?? record.leftBedDate)
                    guard syncable else {
                        try await store.delete(types: writeTypes, deviceID: deviceID, start: clearStart, end: clearEnd, olderThan: nil)
                        guard isCurrent(context) else { return false }
                        receipts[key] = nil
                        failures[key] = nil
                        persistence.set(try JSONEncoder().encode(receipts), forKey: "healthSyncReceipts")
                        continue
                    }
                    let needsVitals = requestedPreferences.sleep || requestedPreferences.heartRate || requestedPreferences.hrv || requestedPreferences.respiration
                    let vitals = needsVitals ? try await api.getVitals(side: side, start: record.enteredBedDate, end: record.leftBedDate) : []
                    guard isCurrent(context) else { return false }
                    let movement = requestedPreferences.sleep ? try await api.getMovement(side: side, start: record.enteredBedDate, end: record.leftBedDate) : []
                    guard isCurrent(context) else { return false }
                    let calibration = requestedPreferences.sleep ? try? await api.getCalibrationStatus(side: side) : nil
                    guard isCurrent(context) else { return false }
                    let analyzer = SleepAnalyzer()
                    // One snapshot of the active model per night: it stages the night and names the receipt. If the
                    // analyzer fell back to the rules, the receipt says so, and the night is retried next sync.
                    let activeModel = stageModels?.active
                    let staging = activeModel.map {
                        SleepAnalyzer.ModelStaging(classifier: $0.classifier, contract: $0.contract, enteredBed: record.enteredBedDate, leftBed: record.leftBedDate)
                    }
                    if requestedPreferences.sleep { analyzer.analyze(vitals: vitals.filter { $0.side == side.rawValue && $0.date >= record.enteredBedDate && $0.date < record.leftBedDate },
                                     movement: movement, calibrationQuality: calibration?.piezo?.qualityScore ?? 0, model: staging) }
                    let stagedBy = analyzer.source == .model ? activeModel?.version : nil
                    let filtered = analyzer.filterOutliers(vitals: vitals.filter { $0.side == side.rawValue && $0.date >= record.enteredBedDate && $0.date < record.leftBedDate })
                    guard isCurrent(context) else { return false }
                    guard !needsVitals || !filtered.isEmpty, !requestedPreferences.sleep || !analyzer.stages.isEmpty else {
                        failures[key] = "Waiting for enough vitals to analyze this night."
                        complete = false
                        continue
                    }
                    if requestedPreferences.presence && TemperatureHistory.presence([record], side: side, in: record.enteredBedDate...record.leftBedDate, now: end).isEmpty {
                        failures[key] = "This record has no complete reported bed-presence intervals."
                        complete = false; continue
                    }
                    let version = nextWriteVersion()
                    let samples = Self.samples(record: record, epochs: analyzer.stages, podID: podID, preferences: requestedPreferences,
                                               vitals: filtered, version: version)
                    guard !samples.isEmpty else {
                        failures[key] = "No eligible Health samples for this night."
                        complete = false
                        continue
                    }
                    let availableTypes = Set(samples.map(\.sampleType))
                    let missingTypes = writeTypes.subtracting(availableTypes)
                    guard isCurrent(context) else { return false }
                    try await store.save(samples)
                    guard isCurrent(context) else { return false }
                    lastSyncSampleCount += samples.count
                    // Save first, then drop whatever this write didn't replace, so a failed save never empties the night.
                    try await store.delete(types: availableTypes, deviceID: deviceID, start: clearStart, end: clearEnd, olderThan: version)
                    guard isCurrent(context) else { return false }
                    Log.health.info("Saved \(samples.count, privacy: .private) samples to Health")
                    guard missingTypes.isEmpty else {
                        failures[key] = missingTypes.contains(HKQuantityType(.heartRateVariabilitySDNN))
                            ? "No eligible recorded SDNN for this night. Other available samples were saved; previous HRV data was kept. Deselect HRV to sync only the available types."
                            : "Some selected measurements are missing. Available samples were saved; missing types' earlier data was kept."
                        complete = false; continue
                    }
                    receipts[key] = Receipt(date: Date(), signature: Self.receiptSignature(requestedPreferences, model: stagedBy),
                                            closedAt: record.leftBedDate, enteredAt: record.enteredBedDate)
                    failures[key] = nil
                    if rebuildProgress != nil { rebuiltKeys.insert(key) }
                    persistence.set(try JSONEncoder().encode(receipts), forKey: "healthSyncReceipts")
                } catch {
                    // A cancelled sync (scene change, backgrounding) retries next time; it isn't a failed night.
                    if Self.isCancellation(error) || !isCurrent(context) { return false }
                    failures[key] = APIError.message(for: error)
                    complete = false
                    Log.health.error("Health sync failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            if Self.isCancellation(error) || !isCurrent(context) { return false }
            authorizationError = APIError.message(for: error)
            Log.health.error("Health sync fetch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return complete
    }

    private struct SyncContext: Equatable {
        let owner: [String]
        let side: String
        let preferences: Preferences
        let model: String?
    }
    private func syncContext() -> SyncContext {
        .init(owner: ownerRevision(), side: Self.linkedSide(defaults: persistence).rawValue, preferences: preferences, model: stageModels?.activeVersion)
    }
    private func isCurrent(_ context: SyncContext) -> Bool { !Task.isCancelled && enabled && syncContext() == context }

    /// HealthKit replacement versions must increase even within one millisecond or after a clock correction.
    private func nextWriteVersion() -> Int {
        let version = max(Int(Date().timeIntervalSince1970 * 1000), persistence.integer(forKey: "healthSyncLastVersion") + 1)
        persistence.set(version, forKey: "healthSyncLastVersion")
        return version
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case APIError.networkError(let underlying) = error {
            return (underlying as? URLError)?.code == .cancelled || underlying is CancellationError
        }
        return (error as? URLError)?.code == .cancelled
    }

    // Sync identifiers, unlike ExternalUUID alone, make retries idempotent in HealthKit.
    // Incrementing the version permits a corrected record to replace earlier samples.
    static func samples(record: SleepRecord, epochs: [SleepAnalyzer.SleepEpoch], podID: String, preferences: Preferences, vitals: [VitalsRecord]? = nil,
                        version: Int = Int(Date().timeIntervalSince1970 * 1000)) -> [HKSample] {
        guard record.enteredBedDate.timeIntervalSince1970 > 0, record.leftBedDate > record.enteredBedDate else { return [] }
        let key = recordKey(podID: podID, record: record)
        let device = HKDevice(name: "sleepypod", manufacturer: nil, model: "Pod",
                              hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                              localIdentifier: deviceID(podID: podID, record: record), udiDeviceIdentifier: nil)
        func metadata(_ epoch: String, type: String, source: String) -> [String: Any] {
            [HKMetadataKeyExternalUUID: "\(key)-\(epoch)", HKMetadataKeyWasUserEntered: false,
             HKMetadataKeySyncIdentifier: "\(key)-\(epoch)-\(type)", HKMetadataKeySyncVersion: version,
             "sleepypod_side": record.side, "sleepypod_source": source]
        }
        var result: [HKSample] = []
        if preferences.presence, let side = Side(rawValue: record.side) {
            let intervals = TemperatureHistory.presence([record], side: side, in: record.enteredBedDate...record.leftBedDate, now: record.leftBedDate)
            for interval in intervals {
                let identifier = "inBed-\(Int64(interval.start.timeIntervalSince1970 * 1000))"
                result.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                    start: interval.start, end: interval.end, device: device, metadata: metadata(identifier, type: "sleep", source: "reported_pod_presence")))
            }
        }
        for epoch in epochs where epoch.start >= record.enteredBedDate && epoch.start < record.leftBedDate {
            let end = min(record.leftBedDate, epoch.start.addingTimeInterval(epoch.duration))
            guard end > epoch.start else { continue }
            let id = String(Int(epoch.start.timeIntervalSince1970))
            if preferences.sleep {
                result.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: stageValue(epoch.stage),
                    start: epoch.start, end: end, device: device, metadata: metadata(id, type: "sleep", source: "on_device_stage_estimate")))
            }
        }
        let values = vitals ?? epochs.map {
            VitalsRecord(id: Int($0.start.timeIntervalSince1970), side: record.side, heartRate: $0.heartRate,
                         hrv: $0.hrv, breathingRate: $0.breathingRate, date: $0.start)
        }
        for vital in values where vital.side == record.side && vital.date >= record.enteredBedDate && vital.date < record.leftBedDate {
            let end = min(record.leftBedDate, vital.date.addingTimeInterval(60))
            let id = String(Int(vital.date.timeIntervalSince1970))
            let quantities: [(Bool, HKQuantityTypeIdentifier, Double?, HKUnit, ClosedRange<Double>)] = [
                (preferences.heartRate, .heartRate, vital.heartRate, .count().unitDivided(by: .minute()), 45...130),
                (preferences.hrv && vital.canWriteSDNN, .heartRateVariabilitySDNN, vital.hrv, .secondUnit(with: .milli), 0.001...300),
                (preferences.respiration, .respiratoryRate, vital.breathingRate, .count().unitDivided(by: .minute()), 8...25)
            ]
            for (enabled, type, value, unit, range) in quantities {
                if enabled, let value, value.isFinite, range.contains(value) {
                    result.append(HKQuantitySample(type: HKQuantityType(type), quantity: HKQuantity(unit: unit, doubleValue: value),
                        start: vital.date, end: end, device: device, metadata: metadata(id, type: type.rawValue, source: "recorded_pod_vitals")))
                }
            }
        }
        return result
    }

    static func stageValue(_ stage: SleepAnalyzer.SleepStage) -> Int {
        switch stage {
        case .wake: HKCategoryValueSleepAnalysis.awake.rawValue
        case .rem: HKCategoryValueSleepAnalysis.asleepREM.rawValue
        case .light: HKCategoryValueSleepAnalysis.asleepCore.rawValue
        case .deep: HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        }
    }

    static func stage(for value: Int) -> SleepAnalyzer.SleepStage? {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .awake: .wake
        case .asleepREM: .rem
        case .asleepCore: .light
        case .asleepDeep: .deep
        default: nil
        }
    }

    // Only what the Watch itself recorded counts; sleepypod's own writes are never compared against themselves.
    // The source's productType is the usual tell, but some samples carry it only on the device.
    static func isWatch(_ sample: HKSample) -> Bool {
        guard sample.sourceRevision.source.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        return sample.sourceRevision.productType?.lowercased().hasPrefix("watch") == true
            || sample.device?.model == "Watch"
            || sample.device?.hardwareVersion?.lowercased().hasPrefix("watch") == true
    }

    static func describeSources(_ samples: [HKSample]) -> String {
        let keys = Set(samples.map {
            "\($0.sourceRevision.source.name)/\($0.sourceRevision.productType ?? "-")/\($0.device?.model ?? "-")"
        })
        return keys.sorted().joined(separator: ", ")
    }

    static func watchStages(_ samples: [HKCategorySample]) -> [WatchComparison.StageSample] {
        samples.filter(isWatch).compactMap { sample in
            stage(for: sample.value).map { WatchComparison.StageSample(start: sample.startDate, end: sample.endDate, stage: $0) }
        }
    }

    static func watchReadings(_ samples: [HKQuantitySample], unit: HKUnit) -> [WatchComparison.Reading] {
        samples.filter(isWatch).map { WatchComparison.Reading(date: $0.startDate, value: $0.quantity.doubleValue(for: unit)) }
    }

    /// Agreement for the whole week plus one value per night, from a single Health read.
    func weekAgreement(nights: [[SleepAnalyzer.SleepEpoch]]) async -> (overall: Double?, nightly: [Double?]) {
        let all = nights.flatMap { $0 }
        guard enabled, preferences.readSleep, let start = all.map(\.start).min(),
              let end = all.map({ $0.start.addingTimeInterval($0.duration) }).max() else { return (nil, nights.map { _ in nil }) }
        let watch = Self.watchStages(await read("sleep") { try await store.sleepSamples(start: start, end: end) })
        return (WatchComparison.stageAgreement(epochs: all, watch: watch).percent,
                nights.map { WatchComparison.stageAgreement(epochs: $0, watch: watch).percent })
    }

    /// How far either side of the bed record the Watch's night may sit and still count as the same night.
    static let watchSearchMargin: TimeInterval = 12 * 3600

    func watchComparison(record: SleepRecord, epochs: [SleepAnalyzer.SleepEpoch], vitals: [VitalsRecord]) async -> WatchComparison? {
        guard enabled, preferences.readSleep || preferences.readVitals, store.available,
              record.leftBedDate > record.enteredBedDate else { return nil }
        readError = nil
        Log.health.notice("Watch comparison for night \(record.id) \(record.enteredBedDate.formatted(.iso8601), privacy: .private) to \(record.leftBedDate.formatted(.iso8601), privacy: .private)")
        // The Watch's night is found on its own terms, then vitals are read over whichever span is wider.
        var stages: [WatchComparison.StageSample] = []
        var start = record.enteredBedDate, end = record.leftBedDate
        if preferences.readSleep {
            let all = Self.watchStages(await read("sleep") {
                try await store.sleepSamples(start: start.addingTimeInterval(-Self.watchSearchMargin), end: end.addingTimeInterval(Self.watchSearchMargin))
            })
            if let session = WatchComparison.session(for: start, end: end, in: WatchComparison.sessions(all)) {
                stages = session.samples
                // Vitals come from the Watch's night, joined with the bed span only when the two actually overlap,
                // so a night matched at a distance never pulls in daytime readings.
                if session.start < end && session.end > start {
                    start = min(start, session.start)
                    end = max(end, session.end)
                } else {
                    start = session.start
                    end = session.end
                }
                Log.health.notice("Watch night \(session.start.formatted(.iso8601), privacy: .private) to \(session.end.formatted(.iso8601), privacy: .private), \(session.samples.count) samples")
            }
        }
        var heartRate: [WatchComparison.Reading] = [], hrv: [WatchComparison.Reading] = [], breathing: [WatchComparison.Reading] = []
        if preferences.readVitals {
            heartRate = Self.watchReadings(await read("heart rate") { try await store.quantitySamples(.heartRate, start: start, end: end) },
                                           unit: .count().unitDivided(by: .minute()))
            hrv = Self.watchReadings(await read("HRV") { try await store.quantitySamples(.heartRateVariabilitySDNN, start: start, end: end) },
                                     unit: .secondUnit(with: .milli))
            breathing = Self.watchReadings(await read("breathing") { try await store.quantitySamples(.respiratoryRate, start: start, end: end) },
                                           unit: .count().unitDivided(by: .minute()))
        }
        Log.health.notice("Watch samples kept: \(stages.count) stages, \(heartRate.count) HR, \(hrv.count) HRV, \(breathing.count) breathing")
        return WatchComparison.build(epochs: epochs, vitals: vitals, watchStages: stages,
                                     watchHeartRate: heartRate, watchHRV: hrv, watchBreathing: breathing)
    }

    func sleepSamples(start: Date, end: Date) async -> [HKCategorySample] {
        guard enabled, preferences.readSleep else { return [] }
        return await read("sleep") { try await store.sleepSamples(start: start, end: end) }
    }

    /// History reads preserve failures instead of presenting an unreadable Health store as zero nights.
    func analysisSleepSamples(start: Date, end: Date) async throws -> [HKCategorySample] {
        guard enabled, preferences.readSleep else {
            throw APIError.notSupported("Enable Apple Health sleep history before reading it.")
        }
        return try await store.sleepSamples(start: start, end: end)
    }

    /// Runs one Health read, logging what came back and keeping the first failure for the UI.
    private func read<S: HKSample>(_ label: String, _ query: () async throws -> [S]) async -> [S] {
        do {
            let samples = try await query()
            let watch = samples.filter(Self.isWatch)
            let span = watch.isEmpty ? "none" : "\(watch.map(\.startDate).min()!.formatted(.iso8601)) to \(watch.map(\.endDate).max()!.formatted(.iso8601))"
            Log.health.notice("Health read \(label, privacy: .public): \(samples.count) samples, \(watch.count) from Watch spanning \(span, privacy: .private); sources: \(Self.describeSources(samples), privacy: .private)")
            return samples
        } catch {
            Log.health.error("Health read \(label) failed: \(error.localizedDescription, privacy: .private)")
            if readError == nil { readError = error.localizedDescription }
            return []
        }
    }

    static func queryScheduleTimes(store: HKHealthStore, start: Date, end: Date) async -> (bed: Date, wake: Date)? {
        let samples = (try? await querySleepSamples(store: store, start: start, end: end)) ?? []
        return scheduleTimes(from: samples)
    }

    static func scheduleTimes(from samples: [HKCategorySample]) -> (bed: Date, wake: Date)? {
        let external = samples.filter { $0.sourceRevision.source.bundleIdentifier != Bundle.main.bundleIdentifier }
        if let inBed = external.first(where: { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }) {
            return (inBed.startDate, inBed.endDate)
        }
        let asleepValues = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                            HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        let asleep = external.filter { asleepValues.contains($0.value) }.sorted { $0.startDate > $1.startDate }
        guard let latest = asleep.first else { return nil }
        var bed = latest.startDate
        let wake = latest.endDate
        for sample in asleep.dropFirst() {
            guard bed.timeIntervalSince(sample.endDate) <= 3600 else { break }
            bed = min(bed, sample.startDate)
        }
        return (bed, wake)
    }

    func inferredSchedule() async -> (bed: Date, wake: Date)? {
        guard enabled, preferences.readSleep else { return nil }
        let samples = await read("sleep") { try await store.sleepSamples(start: Date().addingTimeInterval(-7 * 86400), end: Date()) }
        return Self.scheduleTimes(from: samples)
    }

    static func querySleepSamples(store: HKHealthStore, start: Date, end: Date) async throws -> [HKCategorySample] {
        try await querySamples(store: store, type: HKCategoryType(.sleepAnalysis), start: start, end: end)
    }

    static func querySamples<S: HKSample>(store: HKHealthStore, type: HKSampleType, start: Date, end: Date) async throws -> [S] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForSamples(withStart: start, end: end),
                limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: samples as? [S] ?? []) }
                }
            store.execute(query)
        }
    }
}
