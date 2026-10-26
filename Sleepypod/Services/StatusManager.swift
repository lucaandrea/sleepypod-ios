import Foundation
import Observation

@MainActor
@Observable
final class StatusManager {
    var serverStatus: ServerStatus?
    var services: Services?
    var logSources: [LogSource] = []
    var isLoading = false
    var error: String?
    var lastUpdated: Date?
    var isInternetBlocked = false
    private(set) var serverStatusError: String?
    private(set) var internetError: String?
    private(set) var internetUpdatedAt: Date?
    private(set) var isChangingInternet = false
    private var generation = UUID()
    private var internetRevision = UUID()
    private var internetCooldownUntil: Date?

    private var api: SleepypodProtocol
    private var pollingTask: Task<Void, Never>?

    init(api: SleepypodProtocol) {
        self.api = api
    }

    // Invalidate in-flight responses before changing the connected controller.
    func switchBackend(_ client: SleepypodProtocol) {
        stopPolling()
        generation = UUID(); internetRevision = UUID(); api = client
        serverStatus = nil; services = nil; logSources = []; lastUpdated = nil
        error = nil; serverStatusError = nil; internetError = nil
        internetUpdatedAt = nil; internetCooldownUntil = nil
        isInternetBlocked = false; isChangingInternet = false; isLoading = false
    }

    func statusIsFresh(now: Date = .now) -> Bool {
        guard serverStatusError == nil, let lastUpdated else { return false }
        return (0...30).contains(now.timeIntervalSince(lastUpdated))
    }

    func internetIsFresh(now: Date = .now) -> Bool {
        guard internetError == nil, let internetUpdatedAt else { return false }
        return (0...30).contains(now.timeIntervalSince(internetUpdatedAt))
    }

    // MARK: - Computed

    func categories(schedules: Schedules? = nil) -> [ServiceCategory] {
        guard let status = serverStatus else { return [] }

        // Compute next alarm subtitle from schedule data
        let alarmSubtitle = Self.nextAlarmSubtitle(from: schedules)

        return [
            ServiceCategory(
                name: "Core",
                description: "Server, database, wifi, and scheduler",
                iconName: "server.rack",
                iconColorHex: "4a90d9",
                services: [status.express, status.database, status.logger, status.jobs]
            ),
            ServiceCategory(
                name: "Hardware",
                description: "DAC socket and monitoring",
                iconName: "cpu",
                iconColorHex: "a080d0",
                services: [status.podSocket, status.podSocketMonitor]
            ),
            ServiceCategory(
                name: "Schedules",
                description: "Temperature, power, and alarm jobs",
                subtitle: alarmSubtitle,
                iconName: "calendar",
                iconColorHex: "d4a84a",
                services: [status.temperatureSchedule, status.alarmSchedule, status.powerSchedule,
                           status.primeSchedule, status.rebootSchedule]
            )
            // Biometrics and Calibration are shown as individual cards
            // with real data from their own endpoints — not from ServerStatus
        ].filter { !$0.services.isEmpty }
    }

    // MARK: - Subtitle Helpers

    private static func nextAlarmSubtitle(from schedules: Schedules?) -> String? {
        guard let schedules else { return nil }

        let calendar = Calendar.current
        let now = Date()
        let currentWeekday = calendar.component(.weekday, from: now)

        // Map Calendar weekday (1=Sun) to DayOfWeek
        let dayOrder: [DayOfWeek] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        let todayIndex = currentWeekday - 1

        // Check today and next 7 days for the next enabled alarm
        for dayOffset in 0..<7 {
            let dayIndex = (todayIndex + dayOffset) % 7
            let day = dayOrder[dayIndex]

            // Check left side alarm
            let leftAlarm = schedules.left[day].alarm
            let rightAlarm = schedules.right[day].alarm

            let alarms = [(leftAlarm, "L"), (rightAlarm, "R")].filter { $0.0.enabled }
            guard let earliest = alarms.min(by: { $0.0.time < $1.0.time }) else { continue }

            // If today, check if the alarm time has passed
            if dayOffset == 0 {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                if let alarmDate = formatter.date(from: earliest.0.time) {
                    let alarmComponents = calendar.dateComponents([.hour, .minute], from: alarmDate)
                    let nowComponents = calendar.dateComponents([.hour, .minute], from: now)
                    if let alarmHour = alarmComponents.hour, let alarmMin = alarmComponents.minute,
                       let nowHour = nowComponents.hour, let nowMin = nowComponents.minute {
                        if alarmHour * 60 + alarmMin <= nowHour * 60 + nowMin {
                            continue // Already passed today
                        }
                    }
                }
            }

            let dayLabel = dayOffset == 0 ? "Today" : dayOffset == 1 ? "Tomorrow" : day.displayName
            return "Next alarm: \(dayLabel) at \(earliest.0.time)"
        }

        return "No alarms scheduled"
    }

    var healthyCount: Int {
        serverStatus?.healthyCount ?? 0
    }

    var totalCount: Int {
        serverStatus?.totalCount ?? 0
    }

    var healthProgress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(healthyCount) / Double(totalCount)
    }

    // MARK: - Fetch

    func fetchAll() async {
        guard !isLoading else { return }
        let generation = generation, client = api
        isLoading = true; error = nil
        defer { if self.generation == generation { isLoading = false } }
        async let statusTask: () = fetchServerStatus(client, generation: generation)
        async let servicesTask: () = fetchServices(client, generation: generation)
        async let internetTask: () = fetchInternetStatus(client, generation: generation)
        async let logSourcesTask: () = fetchLogSources(client, generation: generation)
        _ = await (statusTask, servicesTask, internetTask, logSourcesTask)
    }

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                await fetchAll()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Services Control

    func toggleBiometrics() async {
        guard var services else { return }
        services.biometrics.enabled.toggle()
        await updateServices(services)
    }

    func toggleSentryLogging() async {
        guard var services else { return }
        services.sentryLogging.enabled.toggle()
        await updateServices(services)
    }

    private func updateServices(_ proposed: Services) async {
        let generation = generation, client = api
        do {
            let updated = try await client.updateServices(proposed)
            guard current(generation) else { return }
            services = updated
        } catch { if current(generation) { self.error = error.localizedDescription } }
    }

    // MARK: - Internet Access

    func setInternetAccess(blocked: Bool) async {
        guard !isChangingInternet else { return }
        let generation = generation, client = api, previous = isInternetBlocked
        internetRevision = UUID(); isChangingInternet = true; internetError = nil
        isInternetBlocked = blocked
        internetCooldownUntil = Date().addingTimeInterval(10)
        defer { if self.generation == generation { isChangingInternet = false } }
        do {
            try await client.setInternetAccess(blocked: blocked)
            guard current(generation) else { return }
            internetUpdatedAt = .now
        } catch {
            guard current(generation) else { return }
            isInternetBlocked = previous; internetCooldownUntil = nil; internetUpdatedAt = nil
            internetError = "Internet setting was not confirmed. Refresh before changing it again."
            self.error = error.localizedDescription
        }
    }

    // MARK: - Retry

    func retryService(_ service: StatusInfo) async {
        // Re-fetch to pick up any status changes after manual intervention
        await fetchAll()
    }

    // MARK: - Private

    private func current(_ expected: UUID) -> Bool { generation == expected && !Task.isCancelled }

    private func fetchServerStatus(_ client: SleepypodProtocol, generation: UUID) async {
        do {
            let value = try await client.getServerStatus()
            guard current(generation) else { return }
            serverStatus = value; lastUpdated = .now; serverStatusError = nil
        } catch {
            if current(generation) { serverStatusError = error.localizedDescription; self.error = error.localizedDescription }
        }
    }

    private func fetchInternetStatus(_ client: SleepypodProtocol, generation: UUID) async {
        if isChangingInternet { return }
        if let cooldown = internetCooldownUntil, Date() < cooldown { return }
        internetCooldownUntil = nil
        let revision = internetRevision
        do {
            let blocked = try await client.getInternetStatus()
            guard current(generation), internetRevision == revision, !isChangingInternet else { return }
            isInternetBlocked = blocked; internetUpdatedAt = .now; internetError = nil
        } catch {
            if current(generation), internetRevision == revision { internetError = error.localizedDescription }
        }
    }

    private func fetchServices(_ client: SleepypodProtocol, generation: UUID) async {
        do {
            let value = try await client.getServices()
            guard current(generation) else { return }
            services = value
        } catch { if current(generation) { self.error = error.localizedDescription } }
    }

    private func fetchLogSources(_ client: SleepypodProtocol, generation: UUID) async {
        do {
            let value = try await client.getLogSources()
            guard current(generation) else { return }
            logSources = value
        } catch { /* Log-source failures do not invalidate the independent health observation. */ }
    }
}
