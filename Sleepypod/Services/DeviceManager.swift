import Foundation
import Observation

@MainActor
@Observable
final class DeviceManager {
    var deviceStatus: DeviceStatus?
    var isConnected = false
    var isConnecting = false
    var retryCount = 0
    var selectedSide: SideSelection = .left
    var isLinked = false
    var error: String?
    var commandError: String?
    var holdMinutes = UserDefaults.standard.integer(forKey: "temperatureHoldMinutes").validatedHoldMinutes {
        didSet { UserDefaults.standard.set(holdMinutes.validatedHoldMinutes, forKey: "temperatureHoldMinutes") }
    }
    var isSendingMutation = false
    var lastUpdated: Date?

    /// WebSocket supplies fast observations; HTTP still refreshes ownership and notices.
    var isReceivingWebSocket = false

    /// Show spinner for first 3 attempts, then show failed state
    var showConnectionFailed: Bool {
        !isConnected && !isConnecting && retryCount >= 3 && hasPodIP
    }

    var hasPodIP: Bool {
        if OwnerConnection.endpoint != nil { return true }
        guard let ip = UserDefaults.standard.string(forKey: "podIPAddress") else { return false }
        return !ip.isEmpty
    }

    private var api: SleepypodProtocol
    private let now: @MainActor () -> Date
    private var debounceTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var pendingUpdate: DeviceStatusUpdate?
    private var mutationTask: Task<Void, Never>?
    private var mutationCount = 0
    private var connectionGeneration = UUID()
    private var targetOverrides: [Side: (value: Int, until: Date)] = [:]
    private var powerOverrides: [Side: (value: Bool, until: Date)] = [:]
    private var statusRequestID = UUID()

    init(api: SleepypodProtocol, now: @escaping @MainActor () -> Date = { Date() }) {
        self.api = api
        self.now = now
        // Cold-launch hydration: show last-known status immediately so the UI
        // doesn't sit on a "Disconnected" screen for the ~300ms of the first
        // fetch. isConnected stays false until a live fetch confirms the pod
        // is actually reachable — otherwise stale cache could mask an outage.
        if let cached = Self.loadCachedStatus() {
            self.deviceStatus = cached
        }
    }

    /// Becomes true after the first successful network fetch since launch.
    /// Used to prevent stale cache from indefinitely claiming "connected".
    private var hasLiveFetched = false
    private var liveEndpoint: String?

    private static let cacheKey = "cachedDeviceStatus"

    private struct CachedStatus: Codable {
        let endpoint: String
        let status: DeviceStatus
    }

    private static var endpointIdentity: String {
        OwnerConnection.revision.joined(separator: "|")
    }

    private static func loadCachedStatus() -> DeviceStatus? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(CachedStatus.self, from: data),
              cached.endpoint == endpointIdentity else { return nil }
        return cached.status
    }

    private func cacheStatus(_ status: DeviceStatus) {
        let cached = CachedStatus(endpoint: Self.endpointIdentity, status: status)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    // MARK: - Current State Helpers

    var currentSideStatus: SideStatus? {
        guard let status = deviceStatus else { return nil }
        return status.status(for: selectedSide.primarySide)
    }

    var currentOffset: Int {
        guard let status = currentSideStatus else { return 0 }
        return TemperatureConversion.tempFToOffset(status.targetTemperatureF ?? TemperatureConversion.baseTempF)
    }

    var isOn: Bool {
        currentSideStatus?.isOn ?? false
    }

    var isAlarmActive: Bool {
        guard let status = deviceStatus else { return false }
        return status.left.isAlarmVibrating || status.right.isAlarmVibrating
    }

    var alarmSide: Side? {
        guard let status = deviceStatus else { return nil }
        if status.left.isAlarmVibrating { return .left }
        if status.right.isAlarmVibrating { return .right }
        return nil
    }

    // MARK: - Backend Switching

    func switchBackend(_ newClient: SleepypodProtocol) {
        stopPolling()
        debounceTask?.cancel()
        pendingUpdate = nil
        connectionGeneration = UUID()
        mutationTask?.cancel()
        mutationTask = nil
        mutationCount = 0
        isSendingMutation = false
        commandError = nil
        targetOverrides.removeAll()
        powerOverrides.removeAll()
        statusRequestID = UUID()
        api = newClient
        deviceStatus = nil
        hasLiveFetched = false
        isConnected = false
        retryCount = 0
        error = nil
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        startPolling()
    }

    // MARK: - WebSocket Device Status

    /// Accept a device status frame from WebSocket, replacing HTTP poll data.
    func applyWebSocketStatus(_ frame: DeviceStatusFrame) {
        let newStatus = frame.toDeviceStatus(preserving: deviceStatus)
        acceptStatus(newStatus)
    }

    /// Publish a verified snapshot, invalidating older requests that may still finish.
    func acceptStatus(_ status: DeviceStatus) {
        liveEndpoint = Self.endpointIdentity
        statusRequestID = UUID()
        var merged = status
        for side in Side.allCases {
            var observed = status.status(for: side)
            if let target = targetOverrides[side] {
                if observed.targetTemperatureF == target.value || target.until < .now { targetOverrides[side] = nil }
                else { observed.targetTemperatureF = target.value }
            }
            if let power = powerOverrides[side] {
                if observed.isOn == power.value || power.until < .now { powerOverrides[side] = nil }
                else { observed.isOn = power.value }
            }
            if side == .left { merged.left = observed } else { merged.right = observed }
        }
        deviceStatus = merged
        cacheStatus(status)
        hasLiveFetched = true
        isConnected = true
        isConnecting = false
        retryCount = 0
        error = nil
        lastUpdated = now()
    }

    // MARK: - Polling

    func startPolling(immediate: Bool = false) {
        pollingTask?.cancel()
        // If we already have a status snapshot (startConnection just fetched), skip
        // the first immediate poll to avoid a redundant round trip on cold start.
        var skipFirst = hasLiveFetched && !immediate
        pollingTask = Task {
            while !Task.isCancelled {
                if skipFirst {
                    skipFirst = false
                } else if pendingUpdate == nil && !isSendingMutation {
                    await fetchStatus()
                }
                // Retry faster when disconnected, normal interval when connected
                let interval: Duration = isConnected ? .seconds(10) : .seconds(5)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func fetchStatus() async {
        if liveEndpoint != Self.endpointIdentity {
            liveEndpoint = Self.endpointIdentity
            hasLiveFetched = false
            isConnected = false
            isReceivingWebSocket = false
            deviceStatus = Self.loadCachedStatus()
        }
        let requestID = UUID()
        statusRequestID = requestID
        let endpoint = Self.endpointIdentity
        defer {
            if statusRequestID == requestID { isConnecting = false }
        }
        if !isConnected && retryCount < 3 {
            isConnecting = true
        }
        do {
            let status = try await api.getDeviceStatus()
            guard !Task.isCancelled, statusRequestID == requestID,
                  Self.endpointIdentity == endpoint else { return }
            acceptStatus(status)
        } catch {
            guard !Task.isCancelled, statusRequestID == requestID,
                  Self.endpointIdentity == endpoint else { return }
            // A brief network handover can retain a recent snapshot, but a stale
            // connection must never remain green indefinitely after one success.
            let age = lastUpdated.map { now().timeIntervalSince($0) }
            isConnected = hasLiveFetched && age.map { $0 >= 0 && $0 <= 30 } == true
            isConnecting = false
            retryCount += 1
            self.error = "\(error)"
            Log.device.error("fetchStatus failed (attempt \(self.retryCount)): \(error)")
        }
    }

    /// iOS suspends sockets in the background. Resume with an immediate read.
    func resumeConnection() {
        startPolling(immediate: true)
    }

    func suspendConnection() {
        stopPolling()
        statusRequestID = UUID()
        isConnecting = false
        isReceivingWebSocket = false
    }

    func retryConnection() {
        retryCount = 0
        isConnecting = true
        Task { await fetchStatus() }
    }

    // MARK: - Temperature Control

    func adjustOffset(by delta: Int) {
        guard let status = currentSideStatus else { return }
        let currentOffset = TemperatureConversion.tempFToOffset(status.targetTemperatureF ?? TemperatureConversion.baseTempF)
        let newOffset = max(TemperatureConversion.minOffset,
                           min(TemperatureConversion.maxOffset, currentOffset + delta))
        let newTempF = TemperatureConversion.offsetToTempF(newOffset)
        setTemperature(newTempF)
    }

    /// Sets the target for the selected side, or for `side` when given (Both-sides layout).
    /// Linked sides always move together.
    func setTemperature(_ tempF: Int, side: Side? = nil) {
        let clampedTempF = max(TemperatureConversion.minTempF, min(TemperatureConversion.maxTempF, tempF))
        let source = side ?? selectedSide.primarySide
        guard !controlsBlocked(for: source) else { return }
        let sides = (isLinked ? Side.allCases : side.map { [$0] } ?? selectedSide.sides)
            .filter { !controlsBlocked(for: $0) }
        var update = pendingUpdate ?? DeviceStatusUpdate()
        for side in sides {
            targetOverrides[side] = (clampedTempF, .now.addingTimeInterval(8))
            updateLocalTemperature(clampedTempF, for: side)
            if APIBackend.current != .freeSleep {
                powerOverrides[side] = (true, .now.addingTimeInterval(8))
                updateLocalPower(true, for: side)
            }
            let value = SideStatusUpdate(targetTemperatureF: clampedTempF, holdMinutes: holdMinutes.validatedHoldMinutes)
            if side == .left { update.left = value } else { update.right = value }
        }
        pendingUpdate = update
        scheduleDebouncedSend()
    }

    func controlsBlocked(for side: Side) -> Bool {
        deviceStatus?.isPriming == true || deviceStatus?.pumpStallNotifications?[side] != nil
            || deviceStatus?.temperatureControl?[side]?.blocked == "safety"
    }

    // MARK: - Power Control

    func togglePower(side: Side? = nil) {
        let source = side ?? selectedSide.primarySide
        guard let status = deviceStatus?.status(for: source) else { return }
        setPower(!status.isOn, sides: isLinked ? Side.allCases : side.map { [$0] } ?? selectedSide.sides)
    }

    func allOff() { setPower(false, sides: Side.allCases) }

    private func setPower(_ powered: Bool, sides: [Side]) {
        let targets = sides.filter { !powered || !controlsBlocked(for: $0) }
        dropPendingTemperature(for: targets)
        var update = DeviceStatusUpdate()
        for side in targets {
            targetOverrides[side] = nil
            powerOverrides[side] = (powered, .now.addingTimeInterval(8))
            updateLocalPower(powered, for: side)
            let value = SideStatusUpdate(isOn: powered)
            if side == .left { update.left = value } else { update.right = value }
        }
        guard !targets.isEmpty else { return }
        let command = update
        enqueueMutation { api in try await api.updateDeviceStatus(command) }
    }

    /// Resume is queued after an already-sent change and cancels unsent changes on its side.
    func resumeTemperature(side: Side) {
        guard !controlsBlocked(for: side) else { return }
        dropPendingTemperature(for: [side])
        targetOverrides[side] = nil
        powerOverrides[side] = nil
        if APIBackend.current.isDemo {
            deviceStatus?.temperatureControl?[side] = TemperatureControlStatus(source: "schedule")
            return
        }
        guard APIBackend.current == .sleepypodCore else { return }
        do {
            let client = try CoreRESTClient.configured()
            enqueueMutation { _ in try await client.post("device/temperature/resume", body: SideRequest(side: side)) }
        } catch { commandError = error.localizedDescription }
    }

    // MARK: - Notices

    func stopAlarm() {
        let active = Side.allCases.filter { deviceStatus?.status(for: $0).isAlarmVibrating == true }
        let targets = active.isEmpty
            ? Side.allCases.filter { deviceStatus?.snooze?[$0]?.active == true } : active
        for side in targets { updateLocalAlarm(false, for: side) }
        enqueueMutation { api in for side in targets { try await api.clearAlarm(side: side) } }
    }

    func snoozeAlarm() {
        let targets = Side.allCases.filter { deviceStatus?.status(for: $0).isAlarmVibrating == true }
        enqueueMutation { api in for side in targets { _ = try await api.snoozeAlarm(side: side, duration: 300) } }
    }

    func resolvePumpStall(side: Side, restore: Bool) {
        guard let notice = deviceStatus?.pumpStallNotifications?[side], APIBackend.current == .sleepypodCore else { return }
        struct Request: Encodable, Sendable { let side: Side; let alertId: Int? }
        do {
            let client = try CoreRESTClient.configured()
            let path = restore ? "pump-alerts/acknowledge" : "pump-alerts/dismiss-notification"
            let body = Request(side: side, alertId: notice.alertId > 0 ? notice.alertId : nil)
            enqueueMutation { _ in try await client.post(path, body: body) }
        } catch { commandError = error.localizedDescription }
    }

    func dismissPrimeCompletion() {
        guard APIBackend.current == .sleepypodCore else { return }
        do {
            let client = try CoreRESTClient.configured()
            enqueueMutation { _ in try await client.post("device/prime/dismiss", body: [String: String]()) }
        } catch { commandError = error.localizedDescription }
    }

    private struct SideRequest: Encodable, Sendable { let side: Side }

    // MARK: - Side Selection

    func selectSide(_ selection: SideSelection) {
        selectedSide = selection
    }

    func toggleLink() {
        isLinked.toggle()
        if isLinked {
            selectedSide = .both
        } else {
            // Fall back to the primary side when unlinking
            selectedSide = .left
        }
    }

    // MARK: - Private Helpers

    private func updateLocalTemperature(_ tempF: Int, for side: Side) {
        guard var status = deviceStatus else { return }
        switch side {
        case .left: status.left.targetTemperatureF = tempF
        case .right: status.right.targetTemperatureF = tempF
        }
        deviceStatus = status
    }

    private func updateLocalPower(_ isOn: Bool, for side: Side) {
        guard var status = deviceStatus else { return }
        switch side {
        case .left: status.left.isOn = isOn
        case .right: status.right.isOn = isOn
        }
        deviceStatus = status
    }

    private func updateLocalAlarm(_ isVibrating: Bool, for side: Side) {
        guard var status = deviceStatus else { return }
        switch side {
        case .left: status.left.isAlarmVibrating = isVibrating
        case .right: status.right.isAlarmVibrating = isVibrating
        }
        deviceStatus = status
    }

    private func scheduleDebouncedSend() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let update = pendingUpdate else { return }
            pendingUpdate = nil
            // The queue owns sending; cancelling the next tap's debounce must not cancel an in-flight request.
            enqueueMutation { api in try await api.updateDeviceStatus(update) }
        }
    }

    private func dropPendingTemperature(for sides: [Side]) {
        for side in sides {
            if side == .left { pendingUpdate?.left = nil } else { pendingUpdate?.right = nil }
        }
        if pendingUpdate?.left == nil && pendingUpdate?.right == nil {
            pendingUpdate = nil
            debounceTask?.cancel()
        }
    }

    /// Serialize writes so a late dial request cannot re-energize a side after All off or Resume.
    private func enqueueMutation(_ operation: @escaping @MainActor (SleepypodProtocol) async throws -> Void) {
        let previous = mutationTask
        let generation = connectionGeneration
        let client = api
        mutationCount += 1
        isSendingMutation = true
        commandError = nil
        statusRequestID = UUID()
        mutationTask = Task {
            await previous?.value
            guard !Task.isCancelled, generation == connectionGeneration else { return }
            do { try await operation(client) }
            catch {
                guard generation == connectionGeneration else { return }
                commandError = error.localizedDescription
                targetOverrides.removeAll()
                powerOverrides.removeAll()
            }
            guard generation == connectionGeneration else { return }
            mutationCount -= 1
            isSendingMutation = mutationCount > 0
            // Keep the mutation's error visible even when a successful status read follows.
            if mutationCount == 0 {
                mutationTask = nil
                await fetchStatus()
            }
        }
    }

    /// Also used by deterministic command-ordering tests; does not issue additional requests.
    func waitForCommands() async {
        await debounceTask?.value
        await mutationTask?.value
    }
}

private extension Int {
    var validatedHoldMinutes: Int { [15, 30, 60, 120].contains(self) ? self : 30 }
}
