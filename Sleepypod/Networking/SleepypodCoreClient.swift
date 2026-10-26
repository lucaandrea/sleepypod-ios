import Foundation

/// tRPC client for sleepypod-core (Next.js backend).
///
/// Translates `SleepypodProtocol` calls into tRPC HTTP requests.
/// tRPC queries use GET with input as a URL-encoded JSON param.
/// tRPC mutations use POST with JSON body `{"json": input}`.
///
/// Data shape differences between free-sleep and sleepypod-core are
/// handled internally so managers never know which backend is active.
final class SleepypodCoreClient: SleepypodProtocol, @unchecked Sendable {
    private let session: URLSession
    private let configuredBaseURL: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var baseURL: URL? {
        if let configuredBaseURL { return configuredBaseURL }
        if let ownerURL = OwnerConnection.endpoint { return ownerURL }
        guard let ip = UserDefaults.standard.string(forKey: "podIPAddress"), !ip.isEmpty else {
            return nil
        }
        return URL(string: "http://\(ip):3000")
    }

    init(session: URLSession = OwnerConnection.session, baseURL: URL? = nil) {
        self.configuredBaseURL = baseURL
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - Device Status

    func getDeviceStatus() async throws -> DeviceStatus {
        // Keep the first usable status independent of diagnostics and shell-based Wi-Fi queries.
        let status: TRPCDeviceStatus = try await query("device.getStatus")

        return DeviceStatus(
            left: SideStatus(
                currentTemperatureLevel: status.leftSide.currentLevel,
                currentTemperatureF: status.leftSide.currentTemperature.map { Int($0.rounded()) },
                targetTemperatureF: status.leftSide.targetTemperature.map { Int($0.rounded()) },
                secondsRemaining: status.leftSide.heatingDuration,
                // Neutral level zero is a valid powered target; remaining duration indicates power.
                isOn: status.leftSide.heatingDuration > 0,
                isAlarmVibrating: status.leftSide.isAlarmVibrating ?? false,
                taps: mapGestures(status.gestures, side: .left)
            ),
            right: SideStatus(
                currentTemperatureLevel: status.rightSide.currentLevel,
                currentTemperatureF: status.rightSide.currentTemperature.map { Int($0.rounded()) },
                targetTemperatureF: status.rightSide.targetTemperature.map { Int($0.rounded()) },
                secondsRemaining: status.rightSide.heatingDuration,
                isOn: status.rightSide.heatingDuration > 0,
                isAlarmVibrating: status.rightSide.isAlarmVibrating ?? false,
                taps: mapGestures(status.gestures, side: .right)
            ),
            waterLevel: status.waterLevel,
            isPriming: status.isPriming,
            settings: DeviceHardwareSettings(v: 0, gainLeft: 0, gainRight: 0, ledBrightness: 0),
            coverVersion: status.sensorLabel,
            hubVersion: status.podVersion,
            freeSleep: FreeSleepInfo(
                version: "core",
                branch: "main"
            ),
            wifiStrength: status.wifiStrength ?? 0,
            temperatureControl: status.temperatureControl,
            pumpStallNotifications: status.pumpStallNotifications,
            primeCompletedNotification: status.primeCompletedNotification,
            snooze: status.snooze,
            roomClimate: status.roomClimate
        )
    }

    func updateDeviceStatus(_ update: DeviceStatusUpdate) async throws {
        for (side, value) in [("left", update.left), ("right", update.right)] {
            guard let value else { continue }
            if let powered = value.isOn {
                var input: [String: Any] = ["side": side, "powered": powered]
                if powered, let temperature = value.targetTemperatureF {
                    input["temperature"] = temperature
                }
                let _: TRPCSuccess = try await mutate("device.setPower", input: input)
            } else if let temperature = value.targetTemperatureF {
                let _: TRPCSuccess = try await mutate("device.setTemperature", input: [
                    "side": side, "temperature": temperature, "holdMinutes": value.holdMinutes ?? 30
                ])
            }
        }
    }

    // MARK: - Settings

    func getSettings() async throws -> PodSettings {
        let settings: TRPCSettings = try await query("settings.getAll")
        return mapSettingsToFreeFormat(settings)
    }

    func updateSettings(_ settings: PodSettings) async throws -> PodSettings {
        throw APIError.notSupported("Core settings edits require their original snapshot. Reload before saving.")
    }

    // Freeze the controller and compare only edited fields before issuing targeted patches.
    func updateSettings(_ settings: PodSettings, original: PodSettings) async throws -> PodSettings {
        guard let endpoint = baseURL else { throw APIError.noBaseURL }
        let scoped = SleepypodCoreClient(session: session, baseURL: endpoint)
        let ownerRevision = OwnerConnection.revision
        let changes = SettingsChanges(desired: settings, original: original)
        let current = try await scoped.getSettings()
        guard !changes.isEmpty else { return current }
        guard !changes.conflicts(with: current) else {
            throw APIError.serverError(message: "A setting you edited changed on the Pod. Reload and review before saving.")
        }
        let transport = CoreRESTClient(endpoint: endpoint, session: session)
        var sent = false
        var acknowledged = false
        do {
            if !changes.device.isEmpty {
                try ensureCurrentOwner(ownerRevision); sent = true
                try await transport.patch("settings/device", body: changes.device)
                acknowledged = true
            }
            for side in Side.allCases {
                let patch = side == .left ? changes.left : changes.right
                guard !patch.isEmpty else { continue }
                try ensureCurrentOwner(ownerRevision)
                var fields = patch.fields; fields["side"] = .string(side.rawValue)
                sent = true
                try await transport.patch("settings/side", body: SettingsFieldPatch(fields: fields))
                acknowledged = true
            }
            let reported = try await scoped.getSettings()
            guard changes.isReflected(in: reported) else {
                throw APIError.serverError(message: "The latest settings do not reflect every requested change. Reload to inspect the Pod before saving again.")
            }
            return reported
        } catch {
            if acknowledged {
                throw APIError.serverError(message: "A change was acknowledged, but the complete save and readback did not finish. Reload to inspect the latest settings. \(error.localizedDescription)")
            }
            if sent { throw APIError.serverError(message: "Save was not confirmed. Reload before retrying. \(error.localizedDescription)") }
            throw error
        }
    }

    // MARK: - Schedules

    func getSchedules() async throws -> Schedules {
        guard let endpoint = baseURL else { throw APIError.noBaseURL }
        let scoped = SleepypodCoreClient(session: session, baseURL: endpoint)
        return try await scoped.readSchedules()
    }

    private func readSchedules() async throws -> Schedules {
        let left: CoreScheduleRows = try await query("schedules.getAll", input: ["side": "left", "unit": "F"])
        let right: CoreScheduleRows = try await query("schedules.getAll", input: ["side": "right", "unit": "F"])
        return Schedules(left: left.projected, right: right.projected)
    }

    func updateSchedules(_ schedules: Schedules, days: Set<DayOfWeek>? = nil) async throws -> Schedules {
        guard let endpoint = baseURL else { throw APIError.noBaseURL }
        let scoped = SleepypodCoreClient(session: session, baseURL: endpoint)
        let ownerRevision = OwnerConnection.revision
        let selectedDays = days ?? Set(DayOfWeek.allCases)
        var patch = CoreSchedulePatch()
        for side in Side.allCases {
            let latest: CoreScheduleRows = try await scoped.query("schedules.getAll", input: ["side": side.rawValue, "unit": "F"])
            try ensureCurrentOwner(ownerRevision)
            try patch.append(requested: schedules.schedule(for: side), latest: latest, side: side, days: selectedDays)
        }
        if !patch.isEmpty {
            // One transaction preserves all alarms; an owner change cancels an unsent batch.
            try ensureCurrentOwner(ownerRevision)
            let _: TRPCSuccess = try await scoped.mutate("schedules.batchUpdate", input: patch.input)
        }
        return try await scoped.readSchedules()
    }

    private func ensureCurrentOwner(_ revision: [String]) throws {
        try Task.checkCancellation()
        guard OwnerConnection.revision == revision else { throw CancellationError() }
    }

    // MARK: - Server Status

    func getServerStatus() async throws -> ServerStatus {
        let results = try await batchQuery([
            BatchCall(procedure: "health.system", input: nil),
            BatchCall(procedure: "health.scheduler", input: nil),
            BatchCall(procedure: "health.hardware", input: nil),
            BatchCall(procedure: "health.dacMonitor", input: nil),
            BatchCall(procedure: "system.wifiStatus", input: nil)
        ])
        let health = try decoder.decode(TRPCSystemHealth.self, from: results[0].get())
        let scheduler = try decoder.decode(TRPCSchedulerHealth.self, from: results[1].get())

        // Additional health endpoints are non-critical — tolerate per-call failures
        let hardware = tryDecode(TRPCHardwareHealth.self, from: results[2])
        let dacMonitor = tryDecode(TRPCDacMonitor.self, from: results[3])
        let wifi = tryDecode(TRPCWifiStatus.self, from: results[4])

        func info(_ name: String, status: ServiceStatus, desc: String, msg: String = "OK") -> StatusInfo {
            StatusInfo(name: name, status: status, description: desc, message: msg)
        }

        let dbStatus: ServiceStatus = health.database.status == "ok" ? .healthy : .failed
        let schedStatus: ServiceStatus = scheduler.healthy ? .healthy : .failed

        // A missing optional endpoint is unknown, never evidence that hardware is healthy.
        let hwStatus: ServiceStatus = hardware.map { $0.status == "ok" ? .healthy : .failed } ?? .notStarted
        let hwLatency = hardware.map { $0.error ?? $0.latencyMs.map { String(format: "%.1fms", $0) } ?? "Latency unavailable" } ?? "Hardware status unavailable"
        let dacStatus: ServiceStatus
        switch dacMonitor?.status {
        case "running", "polling", "connected": dacStatus = .healthy
        case "error", "disconnected": dacStatus = .failed
        default: dacStatus = .notStarted
        }
        let dacMsg = dacMonitor.map { "\($0.status)\($0.gesturesSupported == true ? " · gestures" : "")" } ?? "DAC monitor status unavailable"
        let wifiStatus: ServiceStatus = wifi.map { $0.connected ? .healthy : .failed } ?? .notStarted
        let wifiMessage = wifi.map { $0.connected ? $0.signal.map { "\($0)% signal" } ?? "Connected · signal unavailable" : "Disconnected" } ?? "Wi-Fi status unavailable"

        return ServerStatus(
            alarmSchedule: info("Alarm Schedule", status: schedStatus, desc: "Wake-up alarm scheduler", msg: "\(scheduler.jobCounts.alarm) alarms"),
            database: info("Database", status: dbStatus, desc: "SQLite database", msg: health.database.error ?? health.database.latencyMs.map { String(format: "%.1fms latency", $0) } ?? "Latency unavailable"),
            express: info("sleepypod core", status: .healthy, desc: "API and hardware bridge"),
            podSocket: info("Hardware Socket", status: hwStatus, desc: "DAC communication", msg: hwLatency),
            podSocketMonitor: info("DAC Monitor", status: dacStatus, desc: "Hardware watchdog", msg: dacMsg),
            jobs: info("Job Scheduler", status: schedStatus, desc: "Background task runner", msg: "Jobs: \(scheduler.jobCounts.total)"),
            logger: info("Wifi", status: wifiStatus,
                         desc: wifi?.ssid ?? "Wireless connection", msg: wifiMessage),
            powerSchedule: info("Power Schedule", status: schedStatus, desc: "Auto on/off scheduler", msg: "\(scheduler.jobCounts.powerOn + scheduler.jobCounts.powerOff) power jobs"),
            primeSchedule: info("Prime Schedule", status: schedStatus, desc: "Daily prime scheduler", msg: "\(scheduler.jobCounts.prime) prime jobs"),
            rebootSchedule: info("Reboot Schedule", status: schedStatus, desc: "Daily reboot scheduler", msg: "\(scheduler.jobCounts.reboot) reboot jobs"),
            systemDate: info("Biometrics", status: .notStarted, desc: "Sleep data processing", msg: "Status unavailable"),
            temperatureSchedule: info("Temperature Schedule", status: schedStatus, desc: "Temperature curve scheduler", msg: "\(scheduler.jobCounts.temperature) temp jobs"),
            coreFirewall: health.iptables,
            coreWiFi: wifi.map { .init(connected: $0.connected, ssid: $0.ssid, signal: $0.signal) }
        )
    }

    // MARK: - Services

    func getServices() async throws -> Services {
        // sleepypod-core doesn't have a services endpoint yet — return unknown state
        let unknown = StatusInfo(name: "unknown", status: .notStarted, description: "Not available", message: "No API endpoint")
        return Services(
            biometrics: Biometrics(
                enabled: false,
                jobs: BiometricsJobs(
                    analyzeSleepLeft: unknown,
                    analyzeSleepRight: unknown,
                    installation: unknown,
                    stream: unknown,
                    calibrateLeft: unknown,
                    calibrateRight: unknown
                )
            ),
            sentryLogging: SentryLogging(enabled: false)
        )
    }

    func updateServices(_ services: Services) async throws -> Services {
        throw APIError.notSupported("Service management is not exposed by sleepypod-core")
    }

    // MARK: - Log Sources

    func getLogSources() async throws -> [LogSource] {
        struct LogSourcesResponse: Decodable {
            let sources: [LogSource]
        }
        let response: LogSourcesResponse = try await query("system.getLogSources")
        return response.sources
    }

    // MARK: - Metrics

    func getSleepRecords(side: Side? = nil, start: Date? = nil, end: Date? = nil) async throws -> [SleepRecord] {
        try await metricRecords("biometrics.getSleepRecords", side: side, start: start, end: end, limit: 100)
    }

    func getVitals(side: Side? = nil, start: Date? = nil, end: Date? = nil) async throws -> [VitalsRecord] {
        do {
            return try await metricRecords("biometrics.getVitals", side: side, start: start, end: end, limit: 20000)
        } catch APIError.serverError(let message) where message.localizedCaseInsensitiveContains("limit") {
            return try await metricRecords("biometrics.getVitals", side: side, start: start, end: end, limit: 1000)
        }
    }

    // Date splitting handles older controllers' smaller limits without truncating an export or chart.
    private func metricRecords<Record: Decodable & Identifiable & Sendable>(_ route: String, side: Side?, start: Date?, end: Date?, limit: Int) async throws -> [Record] where Record.ID: Sendable {
        @Sendable func page(_ lower: Date?, _ upper: Date?) async throws -> [Record] {
            var input: [String: Any] = ["limit": limit]
            if let side { input["side"] = side.rawValue }
            var dateKeys: [String] = []
            if let lower { input["startDate"] = lower.ISO8601Format(); dateKeys.append("startDate") }
            if let upper { input["endDate"] = upper.ISO8601Format(); dateKeys.append("endDate") }
            return try await query(route, input: input, dateKeys: dateKeys)
        }
        if let start, let end {
            return try await MetricRangeLoader.load(start: start, end: end, limit: limit) { lower, upper in try await page(lower, upper) }
        }
        return try await page(start, end)
    }

    func getVitalsSummary(side: Side? = nil, start: Date? = nil, end: Date? = nil) async throws -> VitalsSummary {
        let fmt = ISO8601DateFormatter()
        var input: [String: Any] = [:]
        input["side"] = (side ?? .left).rawValue
        let resolvedEnd = end ?? Date()
        let resolvedStart = start ?? Calendar.current.date(byAdding: .day, value: -7, to: resolvedEnd)!
        input["startDate"] = fmt.string(from: resolvedStart)
        input["endDate"] = fmt.string(from: resolvedEnd)
        let result: VitalsSummary? = try await query("biometrics.getVitalsSummary", input: input, dateKeys: ["startDate", "endDate"])
        return result ?? VitalsSummary(avgHeartRate: nil, minHeartRate: nil, maxHeartRate: nil, avgHRV: nil, avgBreathingRate: nil)
    }

    func getMovement(side: Side? = nil, start: Date? = nil, end: Date? = nil) async throws -> [MovementRecord] {
        try await metricRecords("biometrics.getMovement", side: side, start: start, end: end, limit: 1000)
    }

    func getStageModel(side: Side) async throws -> PodStageModelResponse {
        try await query("sleepStages.getModel", input: ["side": side.rawValue], dateKeys: [])
    }

    func getSleepStages(side: Side, sleepRecordId: Int) async throws -> PodSleepStages {
        try await query("biometrics.getSleepStages", input: ["side": side.rawValue, "sleepRecordId": sleepRecordId])
    }

    // MARK: - Actions

    func triggerAlarm(_ alarm: AlarmJob) async throws {
        let _: TRPCSuccess = try await mutate("device.setAlarm", input: [
            "side": alarm.side.rawValue,
            "vibrationIntensity": alarm.vibrationIntensity,
            "vibrationPattern": alarm.vibrationPattern.rawValue,
            "duration": alarm.duration
        ])
    }

    func clearAlarm(side: Side) async throws {
        let _: TRPCSuccess = try await mutate("device.clearAlarm", input: [
            "side": side.rawValue
        ])
    }

    func getCalibrationStatus(side: Side) async throws -> CalibrationStatus {
        try await query("calibration.getStatus", input: ["side": side.rawValue])
    }

    func triggerCalibration(side: Side, sensorType: String) async throws -> CalibrationTriggerResponse {
        try await mutate("calibration.triggerCalibration", input: ["side": side.rawValue, "sensorType": sensorType])
    }

    func triggerFullCalibration() async throws -> CalibrationTriggerResponse {
        try await mutate("calibration.triggerFullCalibration", input: [:] as [String: String])
    }

    // MARK: - Beta Features (PR #193)

    func getVersion() async throws -> SystemVersion {
        try await query("system.getVersion")
    }

    func snoozeAlarm(side: Side, duration: Int = 300) async throws -> SnoozeResponse {
        try await mutate("device.snoozeAlarm", input: [
            "side": side.rawValue,
            "duration": duration
        ])
    }

    func getWaterLevelLatest() async throws -> WaterLevelReading? {
        try await query("waterLevel.getLatest")
    }

    func getWaterLevelTrend(hours: Int = 24) async throws -> WaterLevelTrend {
        try await query("waterLevel.getTrend", input: ["hours": hours])
    }

    func getAmbientLightLatest() async throws -> AmbientLightReading? {
        try await query("environment.getLatestAmbientLight")
    }

    func getBedTempHistory(start: Date, end: Date, limit: Int, unit: String) async throws -> [BedTempReading] {
        let fmt = ISO8601DateFormatter()
        let input: [String: Any] = [
            "startDate": fmt.string(from: start),
            "endDate": fmt.string(from: end),
            "limit": limit,
            "unit": unit
        ]
        return try await query("environment.getBedTemp", input: input, dateKeys: ["startDate", "endDate"])
    }

    func updateSleepRecord(id: Int, enteredBedAt: Date?, leftBedAt: Date?) async throws {
        var input: [String: Any] = ["id": id]
        let fmt = ISO8601DateFormatter()
        if let d = enteredBedAt { input["enteredBedAt"] = fmt.string(from: d) }
        if let d = leftBedAt { input["leftBedAt"] = fmt.string(from: d) }
        var dateKeys: [String] = []
        if enteredBedAt != nil { dateKeys.append("enteredBedAt") }
        if leftBedAt != nil { dateKeys.append("leftBedAt") }
        // Use mutation — the endpoint is biometrics.updateSleepRecord
        let _: SleepRecord = try await mutate("biometrics.updateSleepRecord", input: input, dateKeys: dateKeys)
    }

    func deleteSleepRecord(id: Int) async throws {
        let _: TRPCSuccess = try await mutate("biometrics.deleteSleepRecord", input: ["id": id])
    }

    func dismissPrimeNotification() async throws {
        let _: TRPCSuccess = try await mutate("device.dismissPrimeNotification", input: [:] as [String: String])
    }

    func startRunOnce(side: Side, setPoints: [RunOnceSetPoint], wakeTime: String) async throws -> RunOnceStartResponse {
        let input: [String: Any] = [
            "side": side.rawValue,
            "setPoints": setPoints.map { ["time": $0.time, "temperature": $0.temperature] as [String: Any] },
            "wakeTime": wakeTime
        ]
        return try await mutate("runOnce.start", input: input)
    }

    func getActiveRunOnce(side: Side) async throws -> RunOnceSession? {
        try await query("runOnce.getActive", input: ["side": side.rawValue])
    }

    func cancelRunOnce(side: Side) async throws {
        let result: TRPCSuccess = try await mutate("runOnce.cancel", input: ["side": side.rawValue])
        guard result.success == true else { throw APIError.serverError(message: "The controller did not confirm run-once cancellation. Refresh its status before trying again.") }
    }

    func getDiskUsage() async throws -> DiskUsage {
        try await query("system.getDiskUsage")
    }

    func getFileCount() async throws -> FileCount {
        try await query("biometrics.getFileCount")
    }

    func getInternetStatus() async throws -> Bool {
        let status: TRPCInternetStatus = try await query("system.internetStatus")
        return status.blocked
    }

    func getLogs(unit: String, lines: Int = 200, priority: String? = nil) async throws -> [String] {
        struct LogPage: Decodable {
            let lines: [String]
            let nextCursor: String?
        }
        var input: [String: Any] = ["unit": unit, "lines": lines]
        if let priority { input["priority"] = priority }
        let page: LogPage = try await query("system.getLogs", input: input)
        return page.lines
    }

    func setInternetAccess(blocked: Bool) async throws {
        let result: TRPCInternetStatus = try await mutate("system.setInternetAccess", input: ["blocked": blocked])
        guard result.blocked == blocked else { throw APIError.serverError(message: "The reported internet setting does not match the request.") }
    }

    func startPriming() async throws {
        let result: TRPCSuccess = try await mutate("device.startPriming", input: [:] as [String: String])
        guard result.success == true else { throw APIError.serverError(message: "The controller did not accept the prime request.") }
    }

    func reboot() async throws {
        throw APIError.notSupported("Reboot is not exposed by sleepypod-core")
    }

    // MARK: - tRPC Transport

    /// tRPC query — GET /api/trpc/{procedure}?input={json}
    /// dateKeys: keys in `input` that should be annotated as Date in superjson meta
    private func query<T: Decodable>(_ procedure: String, input: [String: Any]? = nil, dateKeys: [String] = []) async throws -> T {
        guard let base = baseURL else { throw APIError.noBaseURL }

        var urlString = "\(base)/api/trpc/\(procedure)"
        // tRPC v11 requires input param even for no-input queries
        let inputJSON: String
        if let input, !input.isEmpty {
            let inputData = try JSONSerialization.data(withJSONObject: input)
            inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
        } else {
            inputJSON = "{}"
        }

        // Build superjson envelope with optional meta for Date fields
        var wrapped: String
        if !dateKeys.isEmpty {
            var values: [String: [String]] = [:]
            for key in dateKeys { values[key] = ["Date"] }
            let metaData = try JSONSerialization.data(withJSONObject: ["values": values])
            let metaJSON = String(data: metaData, encoding: .utf8) ?? "{}"
            wrapped = "{\"json\":\(inputJSON),\"meta\":\(metaJSON)}"
        } else {
            wrapped = "{\"json\":\(inputJSON)}"
        }
        let encoded = wrapped.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? wrapped
        urlString += "?input=\(encoded)"

        guard let url = URL(string: urlString) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data, procedure: procedure)
        return try decodeTRPCResult(data)
    }

    /// tRPC mutation — POST /api/trpc/{procedure} with body {"json": input}
    private func mutate<T: Decodable>(_ procedure: String, input: [String: Any], dateKeys: [String] = []) async throws -> T {
        guard let base = baseURL else { throw APIError.noBaseURL }
        guard let url = URL(string: "\(base)/api/trpc/\(procedure)") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        var wrapped: [String: Any] = ["json": input]
        if !dateKeys.isEmpty {
            wrapped["meta"] = ["values": Dictionary(uniqueKeysWithValues: dateKeys.map { ($0, ["Date"]) })]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: wrapped)

        let (data, response) = try await performRequest(request)
        try validateResponse(response, data: data, procedure: procedure)
        return try decodeTRPCResult(data)
    }

    /// tRPC batch query — coalesces multiple queries into one HTTP request.
    /// Mirrors @trpc/client's httpBatchLink format:
    ///   GET /api/trpc/a,b,c?batch=1&input={"0":{"json":...},"1":{"json":...}}
    /// Response is an array; each slot is either result-wrapped or error-wrapped.
    /// Per-call results come back as re-serialized json payloads so callers decode
    /// heterogeneous types into their own models. Per-call errors surface as .failure.
    private func batchQuery(_ calls: [BatchCall]) async throws -> [Result<Data, Error>] {
        guard let base = baseURL else { throw APIError.noBaseURL }
        guard !calls.isEmpty else { return [] }

        let procedures = calls.map(\.procedure).joined(separator: ",")

        var inputMap: [String: Any] = [:]
        for (i, call) in calls.enumerated() {
            inputMap[String(i)] = ["json": call.input ?? [:]]
        }
        let inputData = try JSONSerialization.data(withJSONObject: inputMap)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"
        let encoded = inputJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? inputJSON

        let urlString = "\(base)/api/trpc/\(procedures)?batch=1&input=\(encoded)"
        guard let url = URL(string: urlString) else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8

        let (data, response) = try await performRequest(request)
        try validateResponse(response)

        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let envelope = parsed as? [Any], envelope.count == calls.count else {
            throw APIError.decodingFailed(NSError(
                domain: "tRPC.batch", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Expected array of \(calls.count) results"]
            ))
        }

        return envelope.map { item in
            guard let obj = item as? [String: Any] else {
                return .failure(APIError.decodingFailed(NSError(domain: "tRPC.batch", code: 1)))
            }
            if let err = obj["error"] as? [String: Any] {
                let msg = (err["json"] as? [String: Any])?["message"] as? String
                    ?? err["message"] as? String
                    ?? "tRPC error"
                return .failure(APIError.serverError(message: msg))
            }
            guard let result = obj["result"] as? [String: Any],
                  let dataObj = result["data"] as? [String: Any],
                  let json = dataObj["json"] else {
                return .failure(APIError.decodingFailed(NSError(domain: "tRPC.batch", code: 2)))
            }
            do {
                let bytes = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
                return .success(bytes)
            } catch {
                return .failure(error)
            }
        }
    }

    /// Decode a batch slot optionally — used for non-critical calls that may fail.
    private func tryDecode<T: Decodable>(_ type: T.Type, from result: Result<Data, Error>) -> T? {
        guard let data = try? result.get() else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Decode tRPC response envelope: {"result": {"data": {"json": T}}}
    private func decodeTRPCResult<T: Decodable>(_ data: Data) throws -> T {
        do {
            let envelope = try decoder.decode(TRPCEnvelope<T>.self, from: data)
            return envelope.result.data.json
        } catch {
            Log.network.error("Decode failed: \(error)")
            throw APIError.decodingFailed(error)
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let request = OwnerConnection.authorize(request)
        do {
            return try await session.data(for: request)
        } catch let error as URLError where request.httpMethod == "GET" && Self.isTransient(error) {
            // A pooled keep-alive connection the pod already closed fails once; queries are safe to resend.
            Log.network.info("Retrying \(request.url?.path ?? "?") after \(error.code.rawValue)")
            do {
                return try await session.data(for: request)
            } catch {
                Log.network.error("Request failed: \(request.url?.absoluteString ?? "?") — \(error)")
                throw APIError.networkError(error)
            }
        } catch {
            Log.network.error("Request failed: \(request.url?.absoluteString ?? "?") — \(error)")
            throw APIError.networkError(error)
        }
    }

    static func isTransient(_ error: URLError) -> Bool {
        [.networkConnectionLost, .timedOut, .notConnectedToInternet].contains(error.code)
    }

    private func validateResponse(_ response: URLResponse, data: Data? = nil, procedure: String? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse(statusCode: 0)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let tag = procedure ?? httpResponse.url?.absoluteString ?? "?"
            // Surface the tRPC error message so validation failures aren't silent
            let body = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(500) ?? ""
            Log.network.error("HTTP \(httpResponse.statusCode) \(tag) — \(String(body))")
            if let data,
               let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = envelope["error"] as? [String: Any],
               let payload = error["json"] as? [String: Any],
               let message = payload["message"] as? String {
                throw APIError.serverError(message: message)
            }
            throw APIError.invalidResponse(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Mapping Helpers

    private func fahrenheitToLevel(_ tempF: Double) -> Int {
        Int(((tempF - 82.5) / 27.5) * 100)
    }

    private func minutesFromTime(_ time: String) -> Int? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    private func mapGestures(_ gestures: TRPCGestures?, side: Side) -> TapCounts? {
        guard let g = gestures else { return nil }
        return TapCounts(
            doubleTap: side == .left ? (g.doubleTap?.l ?? 0) : (g.doubleTap?.r ?? 0),
            tripleTap: side == .left ? (g.tripleTap?.l ?? 0) : (g.tripleTap?.r ?? 0),
            quadTap: side == .left ? (g.quadTap?.l ?? 0) : (g.quadTap?.r ?? 0)
        )
    }

    private func mapSettingsToFreeFormat(_ s: TRPCSettings) -> PodSettings {
        let defaultTapConfig = TapConfig.temperature(change: .increment, amount: 2)
        let defaultTaps = TapSettings(doubleTap: defaultTapConfig, tripleTap: defaultTapConfig, quadTap: defaultTapConfig)
        let defaultOverrides = ScheduleOverrides(
            temperatureSchedules: TemperatureScheduleOverride(disabled: false, expiresAt: ""),
            alarm: AlarmOverride(disabled: false, timeOverride: "", expiresAt: "")
        )

        let device = s.device
        let leftSide = s.sides?.left
        let rightSide = s.sides?.right

        func mapSideGestures(_ gestures: [TRPCTapGesture]?) -> TapSettings {
            guard let gestures else { return defaultTaps }
            var taps = defaultTaps
            for g in gestures {
                let config: TapConfig
                if g.actionType == "temperature" {
                    config = .temperature(
                        change: g.temperatureChange == "decrement" ? .decrement : .increment,
                        amount: g.temperatureAmount ?? 2
                    )
                } else {
                    config = .alarm(
                        behavior: g.alarmBehavior == "dismiss" ? .dismiss : .snooze,
                        snoozeDuration: g.alarmSnoozeDuration ?? 300,
                        inactiveAlarmBehavior: g.alarmInactiveBehavior == "power" ? .power : .none
                    )
                }
                switch g.tapType {
                case "doubleTap": taps.doubleTap = config
                case "tripleTap": taps.tripleTap = config
                case "quadTap": taps.quadTap = config
                default: break
                }
            }
            return taps
        }

        return PodSettings(
            timeFormat: device?.timeFormat,
            bedMode: device?.bedMode,
            defaultScheduleEndAction: device?.defaultScheduleEndAction,
            id: "1",
            timeZone: device?.timezone ?? TimeZone.current.identifier,
            left: SideSettings(
                name: leftSide?.name ?? "Left",
                awayMode: leftSide?.awayMode ?? false,
                scheduleOverrides: defaultOverrides,
                taps: mapSideGestures(s.gestures?.left)
            ),
            right: SideSettings(
                name: rightSide?.name ?? "Right",
                awayMode: rightSide?.awayMode ?? false,
                scheduleOverrides: defaultOverrides,
                taps: mapSideGestures(s.gestures?.right)
            ),
            primePodDaily: PrimePodDaily(
                enabled: device?.primePodDaily ?? false,
                time: device?.primePodTime ?? "14:00"
            ),
            temperatureFormat: device?.temperatureUnit == "C" ? .celsius : .fahrenheit,
            rebootDaily: device?.rebootDaily ?? false,
            rebootTime: device?.rebootTime ?? "03:00"
        )
    }

}

// MARK: - tRPC Envelope Types

private struct BatchCall {
    let procedure: String
    let input: [String: Any]?
}

private struct TRPCEnvelope<R: Decodable>: Decodable {
    let result: TRPCResultData<R>
}

private struct TRPCResultData<R: Decodable>: Decodable {
    let data: TRPCJSONWrapper<R>
}

private struct TRPCJSONWrapper<R: Decodable>: Decodable {
    let json: R
}

// MARK: - tRPC Response Types (internal only)

private struct TRPCSuccess: Decodable {
    let success: Bool?
}

private struct TRPCSideStatus: Decodable {
    let currentTemperature: Double?
    let targetTemperature: Double?
    let currentLevel: Int
    let targetLevel: Int
    let heatingDuration: Int
    let isAlarmVibrating: Bool?
}

private struct TRPCGesturePair: Decodable {
    let l: Int
    let r: Int
    let s: Int?
}

private struct TRPCGestures: Decodable {
    let doubleTap: TRPCGesturePair?
    let tripleTap: TRPCGesturePair?
    let quadTap: TRPCGesturePair?
}

private struct TRPCDeviceStatus: Decodable {
    let leftSide: TRPCSideStatus
    let rightSide: TRPCSideStatus
    let waterLevel: String
    let isPriming: Bool
    let podVersion: String
    let sensorLabel: String
    let gestures: TRPCGestures?
    let wifiStrength: Int?
    let temperatureControl: SidePair<TemperatureControlStatus>?
    let pumpStallNotifications: SidePair<PumpStallNotice>?
    let primeCompletedNotification: PrimeCompletion?
    let snooze: SidePair<AlarmSnooze>?
    let roomClimate: RoomClimate?
}

private struct TRPCDeviceSettings: Decodable {
    let timeFormat: String?
    let bedMode: String?
    let defaultScheduleEndAction: ScheduleEndAction?
    let timezone: String?
    let temperatureUnit: String?
    let rebootDaily: Bool?
    let rebootTime: String?
    let primePodDaily: Bool?
    let primePodTime: String?
}

private struct TRPCSideSettings: Decodable {
    let side: String?
    let name: String?
    let awayMode: Bool?
}

private struct TRPCTapGesture: Decodable {
    let side: String
    let tapType: String
    let actionType: String
    let temperatureChange: String?
    let temperatureAmount: Int?
    let alarmBehavior: String?
    let alarmSnoozeDuration: Int?
    let alarmInactiveBehavior: String?
}

private struct TRPCSettings: Decodable {
    let device: TRPCDeviceSettings?
    let sides: TRPCSettingsSides?
    let gestures: TRPCSettingsGestures?
}

private struct TRPCSettingsSides: Decodable {
    let left: TRPCSideSettings?
    let right: TRPCSideSettings?
}

private struct TRPCSettingsGestures: Decodable {
    let left: [TRPCTapGesture]?
    let right: [TRPCTapGesture]?
}

private struct TRPCSystemHealth: Decodable {
    let iptables: ServerStatus.Firewall?
    let status: String
    let database: TRPCDBHealth
    let scheduler: TRPCSchedulerBrief
}

private struct TRPCDBHealth: Decodable {
    let status: String
    let latencyMs: Double?
    let error: String?
}

private struct TRPCSchedulerBrief: Decodable {
    let enabled: Bool
    let jobCount: Int
}

private struct TRPCSchedulerHealth: Decodable {
    let enabled: Bool
    let jobCounts: TRPCJobCounts
    let healthy: Bool
}

private struct TRPCJobCounts: Decodable {
    let total: Int
    let temperature: Int
    let powerOn: Int
    let powerOff: Int
    let alarm: Int
    let prime: Int
    let reboot: Int
}

// Disk usage
struct DiskUsage: Decodable, Sendable {
    let totalBytes: Int
    let usedBytes: Int
    let availableBytes: Int
    let usedPercent: Double

    var usedGB: String { String(format: "%.1f", Double(usedBytes) / 1_073_741_824) }
    var totalGB: String { String(format: "%.1f", Double(totalBytes) / 1_073_741_824) }
    var freeGB: String { String(format: "%.1f", Double(availableBytes) / 1_073_741_824) }
}

// File count
struct FileCount: Decodable, Sendable {
    let rawFiles: RawFileCount
    let totalSizeMB: Double

    struct RawFileCount: Decodable, Sendable {
        let left: Int
        let right: Int
    }

    var totalFiles: Int { rawFiles.left + rawFiles.right }
    var sizeDisplay: String { String(format: "%.0f MB", totalSizeMB) }
}

// Calibration
struct CalibrationSensor: Decodable, Sendable {
    let id: Int
    let side: String
    let sensorType: String
    let status: String
    let qualityScore: Double?
    let samplesUsed: Int?
    let errorMessage: String?
}

struct CalibrationStatus: Decodable, Sendable {
    let capacitance: CalibrationSensor?
    let piezo: CalibrationSensor?
    let temperature: CalibrationSensor?

    var sensors: [CalibrationSensor] { [capacitance, piezo, temperature].compactMap { $0 } }
    var healthyCount: Int { sensors.filter { $0.status == "completed" }.count }
}

// New endpoints
private struct TRPCHardwareHealth: Decodable {
    let status: String
    let socketPath: String?
    let latencyMs: Double?
    let error: String?
}

private struct TRPCDacMonitor: Decodable {
    let status: String
    let podVersion: String?
    let gesturesSupported: Bool?
}

private struct TRPCInternetStatus: Decodable {
    let blocked: Bool
}

private struct TRPCWifiStatus: Decodable {
    let connected: Bool
    let ssid: String?
    let signal: Int?
}
