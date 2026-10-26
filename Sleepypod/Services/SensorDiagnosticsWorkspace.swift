import Foundation
import Observation

@MainActor @Observable final class SensorDiagnosticsWorkspace {
    private let client: any SensorDiagnosticsClient
    private(set) var bed: SensorBedReading?
    private(set) var freezer: SensorFreezerReading?
    private(set) var water: WaterLevelReading?
    private(set) var history: [BedTempReading] = []
    private(set) var summary: SensorEnvironmentSummary?
    private(set) var flow: [SensorFlowReading] = []
    private(set) var temperaturePoints: [SensorTrendPoint] = []
    private(set) var humidityPoints: [SensorTrendPoint] = []
    private(set) var flowPoints: [SensorTrendPoint] = []
    private(set) var rpmPoints: [SensorTrendPoint] = []
    private(set) var errors: [String: String] = [:]
    private(set) var receipts: [String: Date] = [:]
    private(set) var loading: Set<String> = []
    private var requests: [String: UUID] = [:]
    private var historyHours: Int?
    private var flowHours: Int?
    init(client: any SensorDiagnosticsClient) { self.client = client }
    func fresh(_ section: String, now: Date = .now) -> Bool {
        errors[section] == nil && SensorObservation.fresh(receipts[section], now: now)
    }
    func refreshReadings() async {
        guard !loading.contains("Freezer") else { return }
        let request = begin("Freezer"), client = client
        async let nextBed = Self.read { try await client.bed() }
        async let nextFreezer = Self.read { try await client.freezer() }
        async let nextWater = Self.read { try await client.water() }
        let values = await (nextFreezer, nextWater, nextBed)
        defer { finish("Freezer", request: request) }
        guard !Task.isCancelled, requests["Freezer"] == request else { return }
        if case .value(let value) = values.0 { freezer = value }
        if case .value(let value) = values.1 { water = value }
        if case .value(let value) = values.2 { bed = value }
        record(values.0, section: "Freezer"); record(values.1, section: "Water"); record(values.2, section: "Bed")
    }
    func refreshHistory(hours: Int, end: Date = .now) async {
        guard [1, 6, 12, 24].contains(hours) else { return }
        if historyHours != hours {
            history = []; summary = nil; temperaturePoints = []; humidityPoints = []
            receipts["History"] = nil; receipts["Summary"] = nil
        }
        historyHours = hours
        let request = begin("History"), client = client, start = end.addingTimeInterval(-Double(hours) * 3600)
        async let nextHistory = Self.read { try await client.history(start: start, end: end, limit: min(hours * 60, 1440)) }
        async let nextSummary = Self.read { try await client.summary(start: start, end: end) }
        let values = await (nextHistory, nextSummary)
        defer { finish("History", request: request) }
        guard !Task.isCancelled, requests["History"] == request else { return }
        if case .value(let value) = values.0 { prepareHistory(value) }
        if case .value(let value) = values.1 { summary = value }
        record(values.0, section: "History"); record(values.1, section: "Summary")
    }
    func refreshFlow(hours: Int) async {
        guard [1, 6, 24, 72, 168].contains(hours) else { return }
        if flowHours != hours { flow = []; flowPoints = []; rpmPoints = []; receipts["Flow"] = nil }
        flowHours = hours
        let request = begin("Flow"), client = client
        let result = await Self.read { try await client.flow(hours: hours) }
        defer { finish("Flow", request: request) }
        guard !Task.isCancelled, requests["Flow"] == request else { return }
        if case .value(let value) = result { prepareFlow(value) }
        record(result, section: "Flow")
    }
    // Parse and reduce history once per response, outside the frequently updated sensor views.
    private func prepareHistory(_ values: [BedTempReading]) {
        let rows = values.compactMap { row in SensorObservation.date(row.timestamp).map { ($0, row) } }.sorted { $0.0 < $1.0 }
        history = rows.map(\.1)
        temperaturePoints = ["Left", "Right", "Ambient"].flatMap { name in
            SensorTrendPoint.series(name, values: rows.map { date, row in
                (date, name == "Left" ? row.leftCenterTemp ?? row.leftInnerTemp : name == "Right" ? row.rightCenterTemp ?? row.rightInnerTemp : row.ambientTemp)
            })
        }
        humidityPoints = SensorTrendPoint.series("Humidity", values: rows.map { date, row in
            (date, row.humidity.flatMap { (0...100).contains($0) ? $0 : nil })
        })
    }
    private func prepareFlow(_ values: [SensorFlowReading]) {
        flow = values
        let rows = values.compactMap { row in row.date.map { ($0, row) } }
        func points(rpm: Bool) -> [SensorTrendPoint] {
            Side.allCases.flatMap { side in
                SensorTrendPoint.series(side == .left ? "Left" : "Right", values: rows.map { date, row in (date, row.value(side: side, rpm: rpm)) })
            }
        }
        flowPoints = points(rpm: false); rpmPoints = points(rpm: true)
    }
    private func begin(_ section: String) -> UUID {
        let request = UUID(); requests[section] = request; loading.insert(section); return request
    }
    private func finish(_ section: String, request: UUID) { if requests[section] == request { loading.remove(section) } }
    private enum Read<Value: Sendable>: Sendable { case value(Value), failure(String) }
    private nonisolated static func read<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async -> Read<Value> {
        do { return .value(try await operation()) } catch { return .failure(error.localizedDescription) }
    }
    private func record<Value>(_ result: Read<Value>, section: String) {
        switch result {
        case .value: errors[section] = nil; receipts[section] = .now
        case .failure(let message): errors[section] = message
        }
    }
}
