import Foundation
import Observation

enum SystemHealthOperation: Hashable, Sendable {
    case restart(String)
    case calibrate([Side])
}

@MainActor @Observable final class SystemHealthWorkspace {
    private(set) var path: SystemHealthPath?
    private(set) var history: SystemHealthHistory?
    private(set) var pathError: String?
    private(set) var historyError: String?
    private(set) var pathReceivedAt: Date?
    private(set) var historyReceivedAt: Date?
    private(set) var loading = false
    private(set) var acting = false
    private(set) var actionNotice: String?
    private(set) var actionError: String?
    private var actionNeedsReadback = false
    private let client: any SystemHealthClient
    private let calibration: any SensorCalibrationClient
    init(client: any SystemHealthClient, calibration: any SensorCalibrationClient) { self.client = client; self.calibration = calibration }

    func mayAct(at now: Date = .now) -> Bool {
        !acting && !loading && !actionNeedsReadback && pathError == nil && path != nil && pathReceivedAt.map { now.timeIntervalSince($0) <= 30 } == true
    }
    func refresh(history force: Bool = false, now: Date = .now) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await client.path()
            guard !Task.isCancelled else { return }
            path = result; pathError = nil; pathReceivedAt = now; actionNeedsReadback = false
        } catch { if !Task.isCancelled { pathError = error.localizedDescription } }
        if force || historyReceivedAt == nil || now.timeIntervalSince(historyReceivedAt!) >= 60 {
            do {
                let result = try await client.history()
                guard !Task.isCancelled else { return }
                history = result; historyError = nil; historyReceivedAt = now
            } catch { if !Task.isCancelled { historyError = error.localizedDescription } }
        }
    }

    func perform(_ operation: SystemHealthOperation) async {
        guard mayAct() else { actionError = "Refresh health before running a fix."; return }
        acting = true; actionNotice = nil; actionError = nil
        defer { acting = false }
        do {
            switch operation {
            case .restart(let unit):
                guard SystemHealthPath.restartableUnits.contains(unit) else { throw APIError.notSupported("This service cannot be restarted from Health.") }
                let result: HealthServiceRestart
                do { result = try await client.restart(unit: unit) }
                catch { throw APIError.serverError(message: "Restart result was not confirmed. Refresh health and inspect service output before trying again. \(error.localizedDescription)") }
                guard result.ok else { throw APIError.serverError(message: result.message) }
                actionNotice = "Restart accepted. Checking for fresh output; recovery may take a few minutes."
            case .calibrate(let sides):
                guard !sides.isEmpty else { throw APIError.notSupported("No calibration side was selected.") }
                let model = SensorCalibrationWorkspace(client: calibration)
                await model.refresh()
                // Core uses one calibration request file. Wait for each side's new result before queuing the next.
                for side in Side.allCases where sides.contains(side) {
                    try Task.checkCancellation()
                    guard model.canTrigger else { throw APIError.serverError(message: "Calibration is busy or unavailable. Open Calibration to review its status.") }
                    await model.trigger(.init(side: side, kind: .capacitance))
                    while !model.waiting.isEmpty {
                        try Task.checkCancellation()
                        actionNotice = "Waiting for new \(side.displayName.lowercased()) capacitance calibration."
                        await model.refresh()
                        if !model.waiting.isEmpty { try await Task.sleep(for: .seconds(5)) }
                    }
                    guard model.completed else { throw APIError.serverError(message: model.actionError ?? "Calibration completion is unknown. Review status before trying again.") }
                }
                actionNotice = "New capacitance results received. Occupancy may take a minute or two to update."
            }
            try Task.checkCancellation()
            await refresh(history: true)
        } catch is CancellationError {
            actionNeedsReadback = true
            actionError = "Stopped checking the result. A request already accepted by the controller may still finish. Refresh before trying again."
        } catch { actionNeedsReadback = true; actionError = error.localizedDescription }
    }
}
