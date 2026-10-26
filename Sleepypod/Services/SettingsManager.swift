import Foundation
import Observation

@MainActor
@Observable
final class SettingsManager {
    var settings: PodSettings?
    var isLoading = false
    private(set) var isSaving = false
    private(set) var mustReloadSettings = false
    private var settingsRevision = 0
    var error: String?

    private var api: SleepypodProtocol

    init(api: SleepypodProtocol) {
        self.api = api
    }

    func switchBackend(_ client: SleepypodProtocol) {
        settingsRevision += 1; api = client; settings = nil; isLoading = false; isSaving = false; mustReloadSettings = false; error = nil
    }

    // MARK: - Side Names (single source of truth)

    /// Display name for the left side. Falls back to "Left" if not set or empty.
    var leftName: String {
        let name = settings?.left.name ?? ""
        return name.isEmpty ? "Left" : name
    }

    /// Display name for the right side. Falls back to "Right" if not set or empty.
    var rightName: String {
        let name = settings?.right.name ?? ""
        return name.isEmpty ? "Right" : name
    }

    /// Display name for a given side.
    func sideName(for side: Side) -> String {
        side == .left ? leftName : rightName
    }

    /// Keep Health sample identity stable across Bonjour address changes.
    var podID: String { Self.registerPodIdentity(address: Self.healthAddress) }

    static var healthAddress: String {
        let stored = UserDefaults.standard.string(forKey: "podIPAddress") ?? ""
        if !stored.isEmpty { return stored }
        return APIBackend.current == .sleepypodCore ? OwnerConnection.endpoint?.absoluteString ?? "" : ""
    }

    @discardableResult
    static func registerPodIdentity(address: String, bonjourID: String? = nil) -> String {
        guard !address.isEmpty else { return "" }
        let defaults = UserDefaults.standard
        var identities = defaults.dictionary(forKey: "healthPodIdentities") as? [String: String] ?? [:]
        let serviceKey = bonjourID.map { "bonjour:\($0)" }
        let id = serviceKey.flatMap { identities[$0] } ?? identities["address:\(address)"] ?? UUID().uuidString
        identities["address:\(address)"] = id
        if let serviceKey { identities[serviceKey] = id }
        defaults.set(identities, forKey: "healthPodIdentities")
        return id
    }

    func contextSide(selected: Side) -> Side { settings?.contextSide(selected: selected) ?? selected }

    // MARK: - Computed

    var temperatureFormat: TemperatureFormat {
        // Units are Pod-wide; a reported setting takes precedence over the offline display fallback.
        if let settings { return settings.temperatureFormat.degreeUnit }
        if let local = UserDefaults.standard.string(forKey: "temperatureFormat"),
           let format = TemperatureFormat(rawValue: local) {
            return format.degreeUnit
        }
        return (settings?.temperatureFormat ?? .fahrenheit).degreeUnit
    }

    var timeZone: String {
        settings?.timeZone ?? TimeZone.current.identifier
    }

    var podIP: String {
        get { UserDefaults.standard.string(forKey: "podIPAddress") ?? "" }
        set {
            // Strip IPv6 zone IDs (%en0, %%en0) and whitespace
            var clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pct = clean.firstIndex(of: "%") {
                clean = String(clean[clean.startIndex..<pct])
            }
            // Strip ::ffff: IPv4-mapped prefix
            if clean.hasPrefix("::ffff:") {
                clean = String(clean.dropFirst(7))
            }
            UserDefaults.standard.set(clean, forKey: "podIPAddress")
        }
    }

    // MARK: - Fetch

    func fetchSettings() async {
        guard !isSaving else { return }
        settingsRevision += 1
        let revision = settingsRevision
        isLoading = true
        defer { if revision == settingsRevision { isLoading = false } }
        do {
            let value = try await api.getSettings()
            guard revision == settingsRevision, !Task.isCancelled else { return }
            accept(value); error = nil; mustReloadSettings = false
        } catch {
            if revision == settingsRevision, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    var supportsScheduleEndAction: Bool {
        APIBackend.current == .sleepypodCore && settings?.defaultScheduleEndAction != nil
    }

    func updateDefaultScheduleEndAction(_ action: ScheduleEndAction) async {
        guard var settings, supportsScheduleEndAction else { return }
        settings.defaultScheduleEndAction = action
        await saveSettings(settings)
    }

    // MARK: - Updates

    func updateTimeZone(_ tz: String) async {
        guard var settings else { return }
        settings.timeZone = tz
        await saveSettings(settings)
    }

    func updateTemperatureFormat(_ format: TemperatureFormat) async {
        if format == .relative { UserDefaults.standard.set(format.rawValue, forKey: "temperatureFormat"); return }
        guard var settings else { error = "Reload settings before changing the Pod’s units."; return }
        settings.temperatureFormat = format
        await saveSettings(settings)
    }

    func toggleRebootDaily() async {
        guard var settings else { return }
        settings.rebootDaily.toggle()
        await saveSettings(settings)
    }

    func updateRebootTime(_ time: String) async {
        guard var settings else { return }
        settings.rebootTime = time
        await saveSettings(settings)
    }

    func togglePrimePodDaily() async {
        guard var settings else { return }
        settings.primePodDaily.enabled.toggle()
        await saveSettings(settings)
    }

    func updateLEDBrightness(_ brightness: Int) async {
        // LED brightness is in DeviceStatus.settings, not PodSettings
        // Needs device.setLedBrightness endpoint (core#159)
    }

    func updateSideName(_ side: Side, name: String) async {
        guard var settings else { return }
        switch side {
        case .left: settings.left.name = name
        case .right: settings.right.name = name
        }
        await saveSettings(settings)
    }

    /// Rename both sides in one save; nothing is sent when neither name changed.
    /// Returns false if the save failed.
    @discardableResult
    func updateSideNames(left: String, right: String) async -> Bool {
        guard var settings else { return false }
        guard settings.left.name != left || settings.right.name != right else { return true }
        settings.left.name = left
        settings.right.name = right
        return await saveSettings(settings)
    }

    func toggleAwayMode(_ side: Side) async {
        guard var settings else { return }
        switch side {
        case .left: settings.left.awayMode.toggle()
        case .right: settings.right.awayMode.toggle()
        }
        await saveSettings(settings)
    }

    func reboot() async {
        do {
            try await api.reboot()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Private

    @discardableResult
    private func saveSettings(_ desired: PodSettings) async -> Bool {
        guard !isSaving else { return false }
        guard !mustReloadSettings, let original = settings else { if error == nil { error = "Reload settings before saving another change." }; return false }
        isSaving = true; isLoading = false; settingsRevision += 1
        let revision = settingsRevision
        defer { if revision == settingsRevision { isSaving = false } }
        do {
            let value = try await api.updateSettings(desired, original: original)
            guard revision == settingsRevision else { return false }
            accept(value); error = nil; return true
        } catch {
            guard revision == settingsRevision else { return false }
            self.error = error.localizedDescription; mustReloadSettings = true
            return false
        }
    }
    private func accept(_ value: PodSettings) {
        settings = value
        UserDefaults.standard.set(value.timeFormat == "24h" ? "24h" : "12h", forKey: "podTimeFormat")
        UserDefaults.standard.set(value.temperatureFormat.degreeUnit.rawValue, forKey: "temperatureFormat")
    }
}
