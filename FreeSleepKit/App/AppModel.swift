import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    var tab = SleepTab.tonight
    var side = BedSide(rawValue: UserDefaults.standard.string(forKey: "bedSide") ?? "left") ?? .left {
        didSet {
            UserDefaults.standard.set(side.rawValue, forKey: "bedSide")
            if side != oldValue { analytics = nil; analyticsError = nil; recordMessage = nil }
        }
    }
    var device: DeviceStatus?
    var settings: PodSettings?
    var base: BaseStatus?
    var analytics: SleepAnalytics?
    var analyticsError: String?
    var message: String?
    var actionMessage: String?
    var acting = false
    var stopping = false
    var days = 30 { didSet { if days != oldValue { analytics = nil; analyticsError = nil } } }
    private var analyticsKey = ""
    private var analyticsRefreshedAt = Date.distantPast
    let demo: Bool
    let routineWorkspace: RoutineWorkspace
    let journalWorkspace = JournalWorkspace()
    let demoAlarms: DemoAlarms
    let demoHistory = DemoSleepHistory()
    let demoCoachUsage = DemoCoachUsage()
    private(set) var demoPreferences = DeviceDemo.shared?.preferences
    private(set) var preferencesRevision = 0
    private(set) var recordRevision = 0
    private(set) var recordMessage: String?
    var connected: Bool { device != nil }
    private(set) var connectionRevision = 0

    func connectionChanged() {
        connectionRevision += 1
        device = nil; settings = nil; base = nil; analytics = nil; analyticsError = nil
        analyticsKey = ""; analyticsRefreshedAt = .distantPast
        recordMessage = nil
    }

    func recordsChanged(message: String) {
        recordRevision += 1; recordMessage = message
        analytics = nil; analyticsRefreshedAt = .distantPast
        journalWorkspace.saved()
    }
    func preferencesChanged(_ snapshot: PreferencesSnapshot) {
        preferencesRevision += 1
        settings = snapshot.preferences.settings(podID: snapshot.podID)
        analytics = nil; analyticsRefreshedAt = .distantPast; recordRevision += 1
        journalWorkspace.saved()
        if demo {
            demoPreferences = snapshot
            demoHistory.timeZone = snapshot.preferences.timeZone
            demoAlarms.timeZone = TimeZone(identifier: snapshot.preferences.timeZone) ?? .gmt
            demoAlarms.away = [.left: snapshot.preferences.left.awayMode, .right: snapshot.preferences.right.awayMode]
            loadDemo()
        }
    }

    init() {
        demo = AppMode.isDemo
        let workspace = RoutineWorkspace()
        routineWorkspace = workspace
        demoAlarms = DemoAlarms(workspace: workspace)
    }

    func refresh(includeAnalytics: Bool = true) async {
        if demo { loadDemo(); return }
        do {
            let client = try PodClient.configured()
            let requestedConnection = connectionRevision
            let requestedRecords = recordRevision
            let requestedPreferences = preferencesRevision
            let requestedSide = side; let requestedDays = days
            let key = "\(client.baseURL.absoluteString)|\(side.rawValue):\(days)"
            if key != analyticsKey { analytics = nil }
            let refreshNights = includeAnalytics || analytics == nil || key != analyticsKey
                || Date().timeIntervalSince(analyticsRefreshedAt) >= 60
            let previousAnalytics = analytics
            async let preferences: PodSettings? = try? client.get("settings")
            async let status: DeviceStatus? = try? client.get("deviceStatus")
            async let position: BaseStatus? = try? client.get("base")
            async let nights: SleepAnalytics? = refreshNights ? (try? client.get("analytics", query: [
                URLQueryItem(name: "side", value: requestedSide.rawValue), URLQueryItem(name: "days", value: String(requestedDays))])) : previousAnalytics
            let results = await (status, position, nights, preferences)
            guard !Task.isCancelled, requestedSide == side, requestedDays == days,
                  requestedConnection == connectionRevision,
                  requestedRecords == recordRevision,
                  requestedPreferences == preferencesRevision,
                  (try? PodClient.configured().baseURL) == client.baseURL else { return }
            device = results.0; base = results.1; analytics = results.2; settings = results.3
            if refreshNights {
                analyticsKey = key; analyticsRefreshedAt = Date()
                analyticsError = analytics == nil ? "Sleep analytics are unavailable. Check the Pod connection." : nil
            }
            message = device == nil
                ? (UserDefaults.standard.string(forKey: "podNativeAPIPrefix") == "native/v1"
                    ? "These features are unavailable on this Core controller. Check that its native service is installed."
                    : "Your Pod is unavailable. Check its address and token in Settings.") : nil
        } catch { device = nil; base = nil; analytics = nil; analyticsError = error.localizedDescription; message = error.localizedDescription }
    }

    func perform(_ operation: @MainActor () async throws -> Void) async {
        guard !acting else { return }
        acting = true; actionMessage = nil
        defer { acting = false }
        do { try await operation(); await refresh() }
        catch { actionMessage = error.localizedDescription }
    }
    func setTemperature(_ temperature: Double) async {
        await perform {
            if demo { if side == .left { device?.left.targetTemperatureF = temperature } else { device?.right.targetTemperatureF = temperature }; return }
            try await PodClient.configured().post("deviceStatus", body: [side.rawValue: ["targetTemperatureF": temperature]])
        }
    }
    func setPower(_ enabled: Bool) async {
        await perform {
            if demo { if side == .left { device?.left.isOn = enabled } else { device?.right.isOn = enabled }; return }
            try await PodClient.configured().post("deviceStatus", body: [side.rawValue: ["isOn": enabled]])
        }
    }
    func dismissAlarm() async {
        await perform {
            if demo { return }
            try await PodClient.configured().post("deviceStatus", body: [side.rawValue: ["isAlarmVibrating": false]])
        }
    }
    func temperatureLabel(_ fahrenheit: Double) -> String {
        let value = settings?.temperatureFormat == "celsius" ? (fahrenheit - 32) * 5 / 9 : fahrenheit
        return value.formatted(.number.precision(.fractionLength(0)))
    }
    func connectBase() async { await perform { if !demo { try await PodClient.configured().action("base/connect") } } }
    func moveBase(head: Double, feet: Double) async {
        await perform {
            if demo {
                let angles = BaseStatus.Angles(head: head, feet: feet)
                base?.position = .init(left: angles, right: angles); return
            }
            try await PodClient.configured().post("base/position", body: ["head": head, "feet": feet, "speed": 50])
        }
    }
    func stopBase() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        do { if !demo { try await PodClient.configured().action("base/stop") }; await refresh() }
        catch { actionMessage = error.localizedDescription }
    }
    private func loadDemo() {
        if settings == nil, let snapshot = demoPreferences { settings = snapshot.preferences.settings(podID: snapshot.podID) }
        if device == nil { device = .init(left: .init(currentTemperatureF: 82, targetTemperatureF: 84, isOn: true),
            right: .init(currentTemperatureF: 80, targetTemperatureF: 80, isOn: false), isPriming: false, waterLevel: "full") }
        if base == nil { base = .init(state: "connected", position: .init(left: .init(head: 0, feet: 0), right: .init(head: 0, feet: 0)),
            updatedAt: Date().timeIntervalSince1970 * 1000, stale: false, busy: false, error: nil) }
        if analytics == nil { analytics = demoHistory.analytics(side: side, days: days) }
    }
}
