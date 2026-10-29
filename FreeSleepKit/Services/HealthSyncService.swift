import Foundation
import HealthKit
import Observation

@MainActor @Observable
final class HealthSyncService {
    static let shared = HealthSyncService()
    let available = HKHealthStore.isHealthDataAvailable()
    private(set) var busy = false
    private(set) var settings: HealthSyncSettings?
    private(set) var comparison: HealthComparison?
    private(set) var message: String?
    private(set) var backgroundMessage: String?
    private let store = HKHealthStore()
    private let defaults = UserDefaults.standard
    private let settingsKey = "healthSyncSettings.v1"
    private var operation: Task<Int, Error>?
    var canCancel: Bool { operation != nil }
    private var comparisonRefreshedAt = Date.distantPast
    @ObservationIgnored private lazy var engine = HealthSyncEngine(store: HealthKitSampleStore(store: store))
    private let sleepType = HKCategoryType(.sleepAnalysis)
    private let heartType = HKQuantityType(.heartRate)

    private init() {
        if let data = defaults.data(forKey: settingsKey) {
            settings = try? JSONDecoder().decode(HealthSyncSettings.self, from: data)
            if settings == nil { message = "Your Health setup could not be read. Review and save it again before syncing." }
        }
    }
    func authorize() async {
        guard !PersonalWorkspaceBoundary.isActive, available, !busy, !AppMode.isDemo else { return }
        busy = true; defer { busy = false }
        do {
            try await store.requestAuthorization(toShare: [sleepType, heartType],
                read: [sleepType, heartType, HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.respiratoryRate)])
            defaults.set(true, forKey: "healthAuthorizationRequested")
            message = "Permission choices saved. Health keeps read access private; empty results may mean no data or no access."
            try await refreshComparison()
        } catch { message = error.localizedDescription }
    }
    func configure(side: BedSide, exportHeartRate: Bool, automatic: Bool) async {
        guard !busy, !AppMode.isDemo else { return }
        busy = true; defer { busy = false }
        do {
            let identity: HealthExportRecords.Identity = try await PodClient.configured().get("settings")
            guard !identity.id.isEmpty else { throw PodError.message("Your Pod did not provide an identity. Check the connection.") }
            let preserveHistory = settings?.podID == identity.id && settings?.side == side && settings?.exportHeartRate == exportHeartRate
            settings = HealthSyncSettings(podID: identity.id, side: side, exportHeartRate: exportHeartRate, automatic: automatic,
                lastSuccess: preserveHistory ? settings?.lastSuccess : nil,
                lastAttempt: preserveHistory ? settings?.lastAttempt : nil, lastSampleCount: preserveHistory ? settings?.lastSampleCount : nil)
            try persist()
            scheduleBackground()
            message = "Health is linked to your \(side.rawValue) side on this Pod. Run a sync to import its records."
        } catch { message = error.localizedDescription }
    }
    func refreshComparison() async throws {
        guard !PersonalWorkspaceBoundary.isActive, available, !AppMode.isDemo, defaults.bool(forKey: "healthAuthorizationRequested") else { return }
        comparison = try await HealthComparisonReader(store: store).read()
        comparisonRefreshedAt = .now
    }
    func refreshOnActivation() async {
        guard !PersonalWorkspaceBoundary.isActive, !AppMode.isDemo else { return }
        if settings?.automatic == true { _ = try? await synchronize(trigger: .foreground) }
        if !busy && Date().timeIntervalSince(comparisonRefreshedAt) > 60 {
            do { try await refreshComparison() } catch { message = error.localizedDescription }
        }
    }
    func runBackground() async {
        _ = try? await synchronize(trigger: .background)
        scheduleBackground()
    }
    func scheduleBackground() {
        do {
            try HealthBackgroundScheduler.schedule(settings: settings)
            backgroundMessage = settings?.automatic == true
                ? "Automatic sync runs when you open the app and when iOS grants background time. A successful first sync is required."
                : nil
        } catch { backgroundMessage = "Background refresh is unavailable. Sync still runs when you open the app or choose Sync now." }
    }
    func cancel() { operation?.cancel() }

    // One operation serves UI, Shortcuts and background refresh; cancellation propagates to network requests and reconciliation.
    @discardableResult
    func synchronize(trigger: HealthSyncPlan.Trigger = .manual) async throws -> Int? {
        try AppMode.requireLiveConnection()
        guard available else { throw PodError.message("Apple Health is unavailable on this device.") }
        guard !busy else { throw PodError.message("A Health operation is already running.") }
        guard var preferences = settings else { throw PodError.message("Save your personal Health side in sleepypod Settings first.") }
        guard let range = HealthSyncPlan.window(settings: preferences, trigger: trigger, now: .now) else { return nil }
        busy = true; message = "Syncing your \(preferences.side.rawValue) side…"
        defer { busy = false; operation = nil }
        do {
            preferences.lastAttempt = .now; settings = preferences
            try persist()
            let source = PodHealthExportSource(client: try PodClient.configured())
            let task = Task { try await engine.synchronize(source: source, settings: preferences, range: range) }
            operation = task
            let count = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            preferences.lastSuccess = range.end; preferences.lastSampleCount = count; settings = preferences
            try persist()
            message = "Wrote or updated \(count) samples for your \(preferences.side.rawValue) side."
            scheduleBackground()
            // A denied Health read must not turn a successful export into a failed sync.
            try? await refreshComparison()
            return count
        } catch {
            message = error is CancellationError || Task.isCancelled
                ? "Sync cancelled. Completed batches stay saved; sync again to finish."
                : error.localizedDescription
            throw error
        }
    }
    func syncFromButton() async {
        do { _ = try await synchronize() }
        catch where error is CancellationError || Task.isCancelled {
            message = "Sync cancelled. Completed batches stay saved; sync again to finish."
        } catch { message = error.localizedDescription }
    }
    private func persist() throws {
        if let settings { defaults.set(try JSONEncoder().encode(settings), forKey: settingsKey) }
    }
}
