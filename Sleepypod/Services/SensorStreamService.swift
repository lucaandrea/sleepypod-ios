import FreeSleepKit
import Foundation
import Observation
import SwiftUI

// Piezo buffer is just arrays on the @Observable service — no separate class needed.
// All access is @MainActor (append from WebSocket handler, read from view body).

// MARK: - Firmware Log Entry

struct FirmwareLogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String

    enum LogLevel: String, Sendable {
        case debug, info, warn, error
        var color: Color {
            switch self {
            case .debug: Theme.textMuted
            case .info: Theme.healthy
            case .warn: Theme.amber
            case .error: Theme.error
            }
        }
    }
}

// MARK: - Raw Frame Entry

struct RawFrameEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let type: String
    let json: String
}

// MARK: - Service

@MainActor
@Observable
final class SensorStreamService {
    var isConnected = false
    var error: String?
    var lastFrameTime: Date?
    var framesPerSecond: Int = 0

    var presenceUpdatedAt: Date?
    var leftPresence: CapSenseSide?
    var rightPresence: CapSenseSide?
    var leftVitals = LiveVitals()
    var rightVitals = LiveVitals()
    var leftTemps: BedTempSide?
    var rightTemps: BedTempSide?
    var calibrationSignals = CalibrationSignalBuffer()
    var streamActivity = SensorStreamActivity()
    /// When the last bedTemp frame arrived, so views can grey out stale surface readings.
    var bedTempUpdatedAt: Date?
    var frzHealth: FrzHealthFrame?
    var frzTemperature: FrzTemperatureFrame?
    var frzThermal: FrzThermalFrame?
    var mcuTemperature: Float?
    var lastSensorTime: Date?
    var vitalsUpdatedAt: Date?
    private(set) var occupancy: SensorOccupancy?
    private(set) var occupancyUpdatedAt: Date?
    private(set) var occupancyError: String?
    private var occupancyTask: Task<Void, Never>?
    private var occupancyLoading = false
    private var occupancyConnection: String?
    private var connectionIdentity: String { "\(APIBackend.current.rawValue)-\(podURL?.absoluteString ?? "unconfigured")" }
    private(set) var generation = UUID()
    private var measurementTimes: [String: Date] = [:]
    var waveformReplay = SensorWaveformReplay()

    var leftVariance: [Float] = Array(repeating: 0, count: 8)
    var rightVariance: [Float] = Array(repeating: 0, count: 8)

    // Piezo waveform — plain arrays, @MainActor safe
    var piezoLeft: [Int32] = []
    var piezoRight: [Int32] = []
    /// Absolute number one past each channel's newest sample. Never reset, so a sample keeps
    /// its number (and its place in the sweep) after older samples are trimmed or cleared.
    var piezoLeftEnd = 0
    var piezoRightEnd = 0
    var piezoHz = 500
    /// ~12 s per channel: one 8 s sweep plus the cursor's lag behind the newest sample.
    private var maxPiezoSamples: Int { piezoHz * 12 }

    var firmwareLogs: [FirmwareLogEntry] = []
    var leftTempHistory: [(Date, Float)] = []
    var rightTempHistory: [(Date, Float)] = []

    // Pipeline metrics — per-type frame counts and raw frame buffer
    var frameCounts: [String: Int] = [:]
    var recentFrames: [RawFrameEntry] = []
    private let maxRecentFrames = 200

    /// Latest gesture event from WebSocket
    var lastGesture: GestureFrame?

    /// Latest device status frame from WebSocket (replaces HTTP polling)
    var latestDeviceStatus: DeviceStatusFrame?

    /// Notification relay — set by app to forward pod events
    var notificationRelay: NotificationRelay?

    private var webSocketTask: URLSessionWebSocketTask?
    private var streamURL: URL?
    private var streamOwnerRevision: [String] = []
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var frameCount = 0
    private var fpsTimer: Date = .now
    private var lastCapUpdate: Date = .distantPast
    private var lastPiezoUpdate: Date = .distantPast
    private var leftHistory: [[Float]] = []
    private var rightHistory: [[Float]] = []
    private let varianceWindow = 20
    private let maxLogLines = 50
    private let maxTempHistory = 120
    private var tempHistorySeeded = false

    /// Presence labels use Core's shared occupancy result; variance is activity visualization only.
    func reportedPresence(side: Side, now: Date = .now) -> SensorOccupancy.BedSide? {
        guard occupancyConnection == connectionIdentity, occupancyError == nil, SensorObservation.fresh(occupancyUpdatedAt, age: 10, now: now) else { return nil }
        return occupancy?.side(side)
    }
    var presenceIsFresh: Bool { SensorObservation.fresh(presenceUpdatedAt, age: 30) }
    func isOccupied(side: Side) -> Bool { reportedPresence(side: side)?.occupied == true }
    func presenceLabel(sides: [Side]) -> String {
        let readings = sides.compactMap { reportedPresence(side: $0) }
        if readings.contains(where: { $0.occupied && $0.classification != "light" }) { return "IN BED" }
        if readings.contains(where: { $0.occupied }) { return "LIGHT LOAD" }
        return readings.count == sides.count && readings.allSatisfy(\.available) ? "EMPTY" : "PRESENCE UNKNOWN"
    }
    func refreshOccupancy(client supplied: (any SensorDiagnosticsClient)? = nil) async {
        guard !occupancyLoading else { return }
        let requestedGeneration = generation, requestedConnection = connectionIdentity
        occupancyLoading = true
        defer { if requestedGeneration == generation { occupancyLoading = false } }
        let client = supplied ?? (APIBackend.current.isDemo ? DemoSensorDiagnosticsClient() : CoreSensorDiagnosticsClient())
        do {
            let result = try await client.occupancy()
            guard !Task.isCancelled, generation == requestedGeneration, requestedConnection == connectionIdentity else { return }
            occupancyConnection = requestedConnection
            occupancy = result; occupancyUpdatedAt = .now; occupancyError = nil
        } catch {
            guard !Task.isCancelled, generation == requestedGeneration, requestedConnection == connectionIdentity else { return }
            occupancyError = error.localizedDescription
        }
    }
    private func startOccupancy() {
        occupancyTask?.cancel()
        occupancyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refreshOccupancy()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private var podURL: URL? {
        if OwnerConnection.endpoint != nil { return OwnerConnection.streamURL }
        guard let ip = UserDefaults.standard.string(forKey: "podIPAddress"), !ip.isEmpty else { return nil }
        return URL(string: "ws://\(ip):3001")
    }

    var isCurrentPod: Bool {
        if APIBackend.current.isDemo { return demoTask != nil }
        return podURL != nil && streamURL == podURL && streamOwnerRevision == OwnerConnection.revision
    }

    /// Rebuild a suspended socket when the app returns to the foreground.
    func reconnect() {
        disconnect()
        connect()
    }

    func connect() {
        guard !PersonalWorkspaceBoundary.isActive else { disconnect(); return }
        // Demo mode — generate fake sensor data instead of connecting WS
        if APIBackend.current.isDemo {
            guard demoTask == nil else { return }
            disconnect()
            startDemoStream()
            return
        }

        guard webSocketTask == nil || !isCurrentPod else { return }

        guard let url = podURL else { error = "No pod IP"; return }
        disconnect()

        let session = OwnerConnection.session
        var request = OwnerConnection.streamRequest(for: url)
        request.setValue("sensor-snapshot-v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let ws = session.webSocketTask(with: request)
        self.webSocketTask = ws
        streamURL = url
        streamOwnerRevision = OwnerConnection.revision
        ws.resume()
        error = nil
        startOccupancy()
        Task { try? await ws.send(.string(#"{"type":"subscribe","snapshot":true,"sensors":[]}"#)) }

        receiveTask = Task { [weak ws] in
            guard let ws else { return }
            await self.receiveLoop(ws)
        }

        pingTask = Task { [weak self, weak ws] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let ws else { return }
                ws.sendPing { [weak self, weak ws] failure in
                    guard failure != nil else { return }
                    Task { @MainActor in
                        guard let self, let ws, self.webSocketTask === ws else { return }
                        self.disconnect()
                        self.scheduleReconnect()
                    }
                }
            }
        }

        // Seed temp trend from tRPC historical data (once per session)
        if !tempHistorySeeded {
            Task { await self.seedTempHistory() }
        }
    }

    /// Fetch last hour of bed temp from tRPC to pre-populate the trend chart.
    private func seedTempHistory() async {
        guard !tempHistorySeeded, isCurrentPod else { return }
        let requestedURL = podURL
        let requestedGeneration = generation
        do {
            let end = Date()
            let start = end.addingTimeInterval(-3600)
            let readings = try await APIBackend.current.createClient().getBedTempHistory(
                start: start, end: end, limit: maxTempHistory, unit: "F"
            )
            guard !readings.isEmpty, !tempHistorySeeded,
                  requestedURL == podURL, isCurrentPod, requestedGeneration == generation else { return }
            tempHistorySeeded = true

            // tRPC returns descending — reverse for chronological
            let sorted = readings.reversed()
            for reading in sorted {
                guard let date = reading.date else { continue }
                if let leftF = reading.leftF {
                    leftTempHistory.append((date, leftF))
                }
                if let rightF = reading.rightF {
                    rightTempHistory.append((date, rightF))
                }
            }
            // Trim to max
            if leftTempHistory.count > maxTempHistory { leftTempHistory = Array(leftTempHistory.suffix(maxTempHistory)) }
            if rightTempHistory.count > maxTempHistory { rightTempHistory = Array(rightTempHistory.suffix(maxTempHistory)) }
        } catch {
            // Non-fatal — live frames will still populate the chart
        }
    }

    func disconnect() {
        generation = UUID()
        waveformReplay = .init()
        occupancyTask?.cancel(); occupancyTask = nil; occupancyLoading = false
        occupancy = nil; occupancyUpdatedAt = nil; occupancyError = nil; occupancyConnection = nil
        measurementTimes = [:]; lastSensorTime = nil; lastFrameTime = nil; framesPerSecond = 0
        leftTemps = nil; rightTemps = nil; bedTempUpdatedAt = nil; mcuTemperature = nil
        frzHealth = nil; frzTemperature = nil; frzThermal = nil
        leftVitals = .init(); rightVitals = .init(); vitalsUpdatedAt = nil
        leftVariance = []; rightVariance = []; piezoLeft = []; piezoRight = []
        leftTempHistory = []; rightTempHistory = []; tempHistorySeeded = false
        lastPiezoUpdate = .distantPast; frameCount = 0; fpsTimer = .now
        lastGesture = nil; firmwareLogs = []; recentFrames = []; frameCounts = [:]
        demoTask?.cancel(); demoTask = nil
        receiveTask?.cancel(); receiveTask = nil
        pingTask?.cancel(); pingTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        streamURL = nil
        streamOwnerRevision = []
        isConnected = false
        latestDeviceStatus = nil
        presenceUpdatedAt = nil; lastCapUpdate = .distantPast
        leftHistory = []; rightHistory = []; leftPresence = nil; rightPresence = nil
        calibrationSignals = .init()
        streamActivity = .init()
    }

    func clearLogs() { firmwareLogs.removeAll() }

    // MARK: - Demo Stream

    func startDemoStream() {
        guard demoTask == nil else { return }
        isConnected = true
        error = nil
        frameCount = 0
        fpsTimer = .now
        startOccupancy()

        var tick = 0
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                tick += 1

                // --- FPS bookkeeping ---
                self.lastFrameTime = .now
                self.lastSensorTime = .now
                self.frameCount += 1
                let elapsed = Date.now.timeIntervalSince(self.fpsTimer)
                if elapsed >= 1 {
                    self.framesPerSecond = Int(Double(self.frameCount) / elapsed)
                    self.frameCount = 0
                    self.fpsTimer = .now
                }

                // --- CapSense (every tick = 0.5s) ---
                let baseValues: [Float] = [15, 16, 14, 15, 12, 13, 3, 3]
                let variation: Float = Float.random(in: -1...1)
                let leftCap = CapSenseSide(
                    values: baseValues.map { $0 + variation + Float.random(in: -0.5...0.5) },
                    status: "good"
                )
                let rightCap = CapSenseSide(
                    values: baseValues.map { $0 * 0.9 + variation + Float.random(in: -0.3...0.3) },
                    status: "good"
                )
                self.leftPresence = leftCap
                self.rightPresence = rightCap
                self.calibrationSignals.append(.capSense2(.init(ts: Int(Date.now.timeIntervalSince1970), left: leftCap, right: rightCap)))
                self.leftHistory.append(leftCap.values)
                self.rightHistory.append(rightCap.values)
                if self.leftHistory.count > self.varianceWindow { self.leftHistory.removeFirst() }
                if self.rightHistory.count > self.varianceWindow { self.rightHistory.removeFirst() }
                self.leftVariance = self.computeVariance(self.leftHistory)
                self.rightVariance = self.computeVariance(self.rightHistory)
                if self.leftHistory.count >= 2 && self.rightHistory.count >= 2 { self.presenceUpdatedAt = .now }
                self.trackDemoFrame("capSense2")

                // --- Piezo (every 2 ticks = 1s) ---
                if tick % 2 == 0 {
                    let freq = 500
                    var left: [Int32] = []
                    var right: [Int32] = []
                    let phase = Double(tick) * 0.5 // seconds elapsed
                    for i in 0..<freq {
                        let t = Double(i) / Double(freq)
                        let breath = sin(2 * .pi * 0.25 * (t + phase)) * 5000
                        let heart = sin(2 * .pi * 1.0 * (t + phase)) * 2000
                        let noise = Double.random(in: -500...500)
                        left.append(Int32(breath + heart + noise))
                        right.append(Int32(breath + heart * 0.8 + noise))
                    }
                    self.piezoHz = freq
                    self.calibrationSignals.append(.piezoDual(.init(ts: Int(Date.now.timeIntervalSince1970), freq: freq, left1: left, right1: right)))
                    self.piezoLeft.append(contentsOf: left)
                    self.piezoRight.append(contentsOf: right)
                    self.piezoLeftEnd += left.count
                    self.piezoRightEnd += right.count
                    if self.piezoLeft.count > self.maxPiezoSamples {
                        self.piezoLeft.removeFirst(self.piezoLeft.count - self.maxPiezoSamples)
                    }
                    if self.piezoRight.count > self.maxPiezoSamples {
                        self.piezoRight.removeFirst(self.piezoRight.count - self.maxPiezoSamples)
                    }

                    self.vitalsUpdatedAt = .now
                    // Simulate vitals from piezo
                    self.leftVitals = LiveVitals(
                        heartRate: 62 + Double.random(in: -2...2),
                        breathingRate: 15 + Double.random(in: -1...1),
                        confidence: 0.85 + Double.random(in: -0.05...0.05)
                    )
                    self.rightVitals = LiveVitals(
                        heartRate: 58 + Double.random(in: -2...2),
                        breathingRate: 14 + Double.random(in: -1...1),
                        confidence: 0.80 + Double.random(in: -0.05...0.05)
                    )
                    self.trackDemoFrame("piezo-dual")
                }

                // --- DeviceStatus (every 4 ticks = 2s) ---
                if tick % 4 == 0 {
                    self.latestDeviceStatus = DeviceStatusFrame(
                        ts: Int(Date().timeIntervalSince1970),
                        leftSide: DeviceStatusFrame.WsSideStatus(
                            currentTemperature: 72 + Double.random(in: -0.5...0.5),
                            targetTemperature: 70,
                            currentLevel: -2,
                            targetLevel: -2,
                            heatingDuration: 0,
                            isAlarmVibrating: false
                        ),
                        rightSide: DeviceStatusFrame.WsSideStatus(
                            currentTemperature: 68 + Double.random(in: -0.5...0.5),
                            targetTemperature: 66,
                            currentLevel: -3,
                            targetLevel: -3,
                            heatingDuration: 0,
                            isAlarmVibrating: false
                        ),
                        waterLevel: "normal",
                        isPriming: false,
                        snooze: nil
                    )
                    self.trackDemoFrame("deviceStatus")
                }

                // --- FrzHealth (every 20 ticks = 10s) ---
                if tick == 1 || tick % 20 == 0 {
                    self.frzTemperature = .init(ts: Int(Date.now.timeIntervalSince1970), left: 2100, right: 2300, amb: 2400, hs: 3600)
                    self.frzHealth = FrzHealthFrame(
                        ts: Int(Date().timeIntervalSince1970),
                        left: FrzSideHealth(
                            tec: FrzSideHealth.TecInfo(current: Float.random(in: 1.5...2.5)),
                            pump: FrzSideHealth.PumpInfo(mode: "normal", rpm: Int.random(in: 1800...2200), water: true),
                            temps: .init(flowrate: 24.5)
                        ),
                        right: FrzSideHealth(
                            tec: FrzSideHealth.TecInfo(current: Float.random(in: 1.5...2.5)),
                            pump: FrzSideHealth.PumpInfo(mode: "normal", rpm: Int.random(in: 1800...2200), water: true),
                            temps: .init(flowrate: 24.5)
                        ),
                        fan: FrzFanHealth(
                            top: FrzFanHealth.FanInfo(rpm: Int.random(in: 2800...3200)),
                            bottom: FrzFanHealth.FanInfo(rpm: Int.random(in: 2800...3200))
                        )
                    )
                    self.trackDemoFrame("frzHealth")
                }

                // --- BedTemp (on start, then every 32 ticks = 16s) ---
                if tick == 1 || tick % 32 == 0 {
                    let ambC: Float = 22.5 + Float.random(in: -0.3...0.3)
                    let huPct: Float = 45 + Float.random(in: -2...2)
                    let leftZones: [Float] = [30.5, 31.2, 29.8, 30.0].map { $0 + Float.random(in: -0.2...0.2) }
                    let rightZones: [Float] = [29.0, 29.8, 28.5, 29.2].map { $0 + Float.random(in: -0.2...0.2) }
                    self.leftTemps = BedTempSide(amb: ambC, hu: huPct, temps: leftZones)
                    self.rightTemps = BedTempSide(amb: ambC, hu: huPct, temps: rightZones)
                    self.bedTempUpdatedAt = .now
                    self.calibrationSignals.append(.bedTemp2(.init(ts: Int(Date.now.timeIntervalSince1970), mcu: nil, left: .init(amb: ambC, hu: huPct, temps: leftZones), right: .init(amb: ambC, hu: huPct, temps: rightZones))))
                    if let avgL = self.leftTemps?.avgSurfaceTempF {
                        self.leftTempHistory.append((.now, Float(avgL)))
                        if self.leftTempHistory.count > self.maxTempHistory { self.leftTempHistory.removeFirst() }
                    }
                    if let avgR = self.rightTemps?.avgSurfaceTempF {
                        self.rightTempHistory.append((.now, Float(avgR)))
                        if self.rightTempHistory.count > self.maxTempHistory { self.rightTempHistory.removeFirst() }
                    }
                    self.trackDemoFrame("bedTemp2")
                }
            }
        }
    }

    private func trackDemoFrame(_ type: String) {
        streamActivity.append(type: type)
        frameCounts[type, default: 0] += 1
        recentFrames.insert(
            RawFrameEntry(timestamp: .now, type: type, json: "{\"type\":\"\(type)\",\"demo\":true}"),
            at: 0
        )
        if recentFrames.count > maxRecentFrames { recentFrames.removeLast() }
    }

    func stopDemoStream() { disconnect() }

    // MARK: - Receive

    private func receiveLoop(_ ws: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await ws.receive()
                guard !Task.isCancelled, webSocketTask === ws else { return }
                guard isCurrentPod else {
                    disconnect()
                    connect()
                    return
                }
                if !isConnected { isConnected = true }
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) { handleFrame(data) }
                case .data(let data):
                    handleFrame(data)
                @unknown default: break
                }
            }
        } catch {
            guard !Task.isCancelled, webSocketTask === ws else { return }
            self.isConnected = false
            self.error = "Disconnected"
            webSocketTask = nil
            scheduleReconnect()
        }
    }

    func handleFrame(_ data: Data, receivedAt now: Date = .now) {
        if let response = try? JSONDecoder().decode(SensorWaveformReplay.Response.self, from: data), response.type == "waveform" {
            waveformReplay.accept(response); return
        }
        struct TimeRange: Decodable { let type: String; let min: Double; let max: Double }
        if let range = try? JSONDecoder().decode(TimeRange.self, from: data), range.type == "time_range" {
            waveformReplay.setRange(.init(min: range.min, max: range.max)); return
        }
        if let batch = SensorSnapshotBatch(data: data) {
            // A snapshot is cached observation, never a new measurement. Each embedded timestamp survives.
            for frame in batch.frames { handleFrame(frame, receivedAt: now) }
            return
        }
        streamActivity.append(data: data, at: now)
        guard let frame = SensorFrame.decode(from: data) else { return }

        lastFrameTime = now
        frameCount += 1
        let elapsed = Date.now.timeIntervalSince(fpsTimer)
        if elapsed >= 1 {
            framesPerSecond = Int(Double(frameCount) / elapsed)
            frameCount = 0
            fpsTimer = .now
        }

        // Track per-type counts and raw frames for pipeline view
        let frameType = frame.typeName
        frameCounts[frameType, default: 0] += 1
        if let jsonStr = String(data: data, encoding: .utf8) {
            recentFrames.insert(RawFrameEntry(timestamp: .now, type: frameType, json: jsonStr), at: 0)
            if recentFrames.count > maxRecentFrames { recentFrames.removeLast() }
        }

        guard let measured = frame.measuredAt, measured <= now else { return }
        // Firmware aliases share one timeline so older dialects cannot replace newer readings.
        let measurementFamily: String
        switch frame {
        case .bedTemp, .bedTemp2: measurementFamily = "bedTemperature"
        case .capSense, .capSense2: measurementFamily = "capacitance"
        default: measurementFamily = frame.typeName
        }
        let previous = measurementTimes[measurementFamily]
        guard previous.map({ measured >= $0 }) ?? true else { return }
        if case .piezoDual = frame, previous == measured { return }
        measurementTimes[measurementFamily] = measured
        if ["piezo-dual", "capSense", "capSense2", "bedTemp", "bedTemp2", "frzHealth", "frzTemp", "frzTherm"].contains(frame.typeName) {
            lastSensorTime = max(lastSensorTime ?? measured, measured)
        }
        calibrationSignals.append(frame, at: measured)

        switch frame {
        case .capSense2(let cap), .capSense(let cap):
            guard now.timeIntervalSince(lastCapUpdate) > 0.2 else { return }
            lastCapUpdate = now
            leftPresence = cap.left
            rightPresence = cap.right
            leftHistory.append(cap.left.values)
            rightHistory.append(cap.right.values)
            if leftHistory.count > varianceWindow { leftHistory.removeFirst() }
            if rightHistory.count > varianceWindow { rightHistory.removeFirst() }
            leftVariance = computeVariance(leftHistory)
            rightVariance = computeVariance(rightHistory)
            if leftHistory.count >= 2 && rightHistory.count >= 2 { presenceUpdatedAt = measured }

        case .piezoDual(let piezo):
            guard piezo.freq > 0, piezo.freq <= 4000 else { return }
            piezoHz = piezo.freq
            piezoLeft.append(contentsOf: piezo.left1)
            piezoRight.append(contentsOf: piezo.right1)
            piezoLeftEnd += piezo.left1.count
            piezoRightEnd += piezo.right1.count
            if piezoLeft.count > maxPiezoSamples { piezoLeft.removeFirst(piezoLeft.count - maxPiezoSamples) }
            if piezoRight.count > maxPiezoSamples { piezoRight.removeFirst(piezoRight.count - maxPiezoSamples) }

            guard now.timeIntervalSince(lastPiezoUpdate) > 1.0 else { return }
            lastPiezoUpdate = now
            guard SensorObservation.fresh(measured, age: 10, now: now), piezo.freq > 0 else { return }
            let requestedGeneration = generation
            let left = piezo.left1, right = piezo.right1, freq = piezo.freq
            Task.detached(priority: .utility) { [weak self] in
                let lv = PiezoAnalyzer.extractVitals(signal: left, sampleRate: freq)
                let rv = PiezoAnalyzer.extractVitals(signal: right, sampleRate: freq)
                await MainActor.run { [weak self] in
                    guard let self, self.generation == requestedGeneration, self.isCurrentPod,
                          SensorObservation.fresh(measured, age: 10),
                          self.vitalsUpdatedAt.map({ measured >= $0 }) ?? true else { return }
                    self.leftVitals = lv.confidence > 0.1 ? lv : .init()
                    self.rightVitals = rv.confidence > 0.1 ? rv : .init()
                    self.vitalsUpdatedAt = measured
                }
            }

        case .bedTemp2(let temp), .bedTemp(let temp):
            leftTemps = temp.left
            rightTemps = temp.right
            bedTempUpdatedAt = measured
            mcuTemperature = temp.mcu
            tempHistorySeeded = true
            if let avgL = temp.left.avgSurfaceTempF {
                leftTempHistory.append((measured, Float(avgL)))
                if leftTempHistory.count > maxTempHistory { leftTempHistory.removeFirst() }
            }
            if let avgR = temp.right.avgSurfaceTempF {
                rightTempHistory.append((measured, Float(avgR)))
                if rightTempHistory.count > maxTempHistory { rightTempHistory.removeFirst() }
            }

        case .frzHealth(let frz):
            frzHealth = frz
        case .frzTemp(let frame): frzTemperature = frame
        case .frzTherm(let frame): frzThermal = frame

        case .log(let log):
            let entry = FirmwareLogEntry(
                timestamp: Date(timeIntervalSince1970: Double(log.ts)),
                level: FirmwareLogEntry.LogLevel(rawValue: log.level) ?? .info,
                message: log.msg
            )
            firmwareLogs.append(entry)
            if firmwareLogs.count > maxLogLines { firmwareLogs.removeFirst() }

        case .notification(let notif):
            guard SensorObservation.fresh(measured, age: 30, now: now) else { return }
            Task {
                await notificationRelay?.relay(
                    category: notif.category,
                    title: notif.title,
                    message: notif.message
                )
            }

        case .deviceStatus(let status):
            if SensorObservation.fresh(measured, age: 30, now: now) { latestDeviceStatus = status }

        case .gesture(let g):
            guard SensorObservation.fresh(measured, age: 5, now: now) else { return }
            lastGesture = g
            let entry = FirmwareLogEntry(
                timestamp: Date(),
                level: .info,
                message: "[\(g.tapType)] \(g.side) side tapped"
            )
            firmwareLogs.append(entry)
            if firmwareLogs.count > maxLogLines { firmwareLogs.removeFirst() }

        case .unknown: break
        }
    }

    private func computeVariance(_ history: [[Float]]) -> [Float] {
        guard history.count >= 2 else { return Array(repeating: 0, count: 8) }
        let n = history.map(\.count).min() ?? 0
        guard n > 0 else { return Array(repeating: 0, count: 8) }
        var result = [Float](repeating: 0, count: n)
        for ch in 0..<n {
            let vals = history.compactMap { $0[safe: ch] }
            guard vals.count >= 2 else { continue }
            let mean = vals.reduce(0, +) / Float(vals.count)
            let v = vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(vals.count)
            result[ch] = sqrt(v)
        }
        return result
    }

    func requestWaveformRange() async {
        if APIBackend.current.isDemo, demoTask != nil {
            waveformReplay.setRange(.init(min: Date.now.timeIntervalSince1970 - 300, max: Date.now.timeIntervalSince1970)); return
        }
        guard let socket = webSocketTask else { return }
        try? await socket.send(.string(#"{"type":"get_time_range"}"#))
    }
    func seekWaveform(at time: Double) async {
        guard isConnected, let request = waveformReplay.begin(at: time) else { return }
        let requestedGeneration = generation
        if APIBackend.current.isDemo {
            let frames = (0..<10).map { offset -> PiezoDualFrame in
                let samples = (0..<500).map { Int32(sin(Double($0) / 20) * 1000) }
                return .init(ts: Int(time) + offset, freq: 500, left1: samples, right1: samples.map { $0 / 2 })
            }
            waveformReplay.accept(.init(type: "waveform", requestId: request, frames: frames)); return
        }
        guard let socket = webSocketTask else { waveformReplay.fail("Stream disconnected", request: request); return }
        struct Command: Encodable { let type = "get_waveform"; let timestamp: Double; let requestId: Int }
        do {
            let data = try JSONEncoder().encode(Command(timestamp: time, requestId: request))
            try await socket.send(.data(data))
            try await Task.sleep(for: .seconds(5))
            guard generation == requestedGeneration else { return }
            waveformReplay.fail("Waveform request timed out. Try another position or return to live.", request: request)
        } catch {
            guard !Task.isCancelled, generation == requestedGeneration else { return }
            waveformReplay.fail(error.localizedDescription, request: request)
        }
    }

    private func scheduleReconnect() {
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            connect()
        }
    }
}
