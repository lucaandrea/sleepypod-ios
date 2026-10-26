import Foundation
import Observation

@MainActor @Observable final class SystemThermalWorkspace {
    private(set) var snapshot: SystemThermalSnapshot?
    private(set) var history: SystemThermalHistory?
    private(set) var range: ThermalRange = .twelveHours
    private(set) var live: [ThermalHistoryPoint] = []
    private(set) var snapshotError: String?
    private(set) var historyError: String?
    private(set) var snapshotReceivedAt: Date?
    private(set) var historyReceivedAt: Date?
    private(set) var loadingSnapshot = false
    private(set) var loadingHistory = false
    private var revision = 0
    private let client: any SystemThermalClient
    init(client: any SystemThermalClient) { self.client = client }
    func setRange(_ range: ThermalRange) {
        guard range != self.range else { return }
        revision += 1; self.range = range; history = nil; historyError = nil; historyReceivedAt = nil; loadingHistory = false
    }
    func refreshSnapshot(now: Date = .now) async {
        guard !loadingSnapshot else { return }
        loadingSnapshot = true
        defer { loadingSnapshot = false }
        do {
            let value = try await client.snapshot()
            guard !Task.isCancelled else { return }
            snapshot = value; snapshotError = nil; snapshotReceivedAt = now
            live = Array((live + [value.point(at: now)]).filter { now.timeIntervalSince1970 * 1000 - $0.timestamp <= 1_800_000 }.suffix(360))
        } catch { if !Task.isCancelled { snapshotError = error.localizedDescription } }
    }
    func refreshHistory() async {
        guard range != .live else { return }
        revision += 1; let requested = revision; let range = range
        loadingHistory = true
        defer { if revision == requested { loadingHistory = false } }
        do {
            let value = try await client.history(range)
            guard !Task.isCancelled, revision == requested else { return }
            guard value.range == range.rawValue, value.to > value.from, value.bucketSec > 0 else { throw APIError.serverError(message: "The controller returned an invalid thermal history window.") }
            history = value; historyError = nil; historyReceivedAt = .now
        } catch { if !Task.isCancelled, revision == requested { historyError = error.localizedDescription } }
    }
    var chart: ThermalChartData? {
        if range == .live {
            guard live.count > 1, let first = live.first, let last = live.last, last.timestamp > first.timestamp else { return nil }
            let power = (snapshot?.sides ?? []).compactMap { side -> SystemThermalHistory.PowerOn? in
                guard side.isPowered, let date = SensorCalibrationProfile.date(side.poweredOnAt) else { return nil }
                return .init(side: side.side, at: date.timeIntervalSince1970 * 1000)
            }
            let available = Dictionary(uniqueKeysWithValues: ThermalPanel.allCases.map { panel in (panel.rawValue, live.contains { point in panel.signals.contains { point.values[$0] != nil } }) })
            return .init(from: first.timestamp, to: last.timestamp, gap: 20_000, points: live, powerOn: power, available: available, bedTargetSince: first.timestamp)
        }
        guard let history, history.range == range.rawValue else { return nil }
        return .init(from: history.from, to: history.to, gap: history.bucketSec * 3000, points: history.points.sorted { $0.timestamp < $1.timestamp }, powerOn: history.powerOn, available: history.available, bedTargetSince: history.bedTargetSince)
    }
}
