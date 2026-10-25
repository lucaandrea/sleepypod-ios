import Foundation
import Observation

@MainActor @Observable
final class SleepRangeExportWorkspace {
    struct DataSet {
        let window: DateInterval
        let sleep: [SleepRecord]
        let vitals: [VitalsRecord]
        let movement: [MovementRecord]
    }
    var result: DataSet?
    var error: String?
    var loading = false
    private let api: any SleepypodProtocol
    private var revision = 0
    init(api: any SleepypodProtocol) { self.api = api }

    // First select records using the same night boundary as the screen, then extend raw readings through their wake times.
    func load(side: Side, nights: DateInterval, now: Date = .now) async {
        revision += 1; let selectedRevision = revision
        loading = true; error = nil; result = nil
        do {
            let records = try await api.getSleepRecords(side: side, start: nights.start, end: nights.end)
                .filter { $0.side == side.rawValue && $0.enteredBedDate >= nights.start && $0.enteredBedDate < nights.end }
                .sorted { $0.enteredBedDate < $1.enteredBedDate }
            try Task.checkCancellation()
            let window = SleepCalendar.exportWindow(nights: nights, records: records, now: now)
            async let vitals = api.getVitals(side: side, start: window.start, end: window.end)
            async let movement = api.getMovement(side: side, start: window.start, end: window.end)
            let readings = try await (vitals, movement)
            guard selectedRevision == revision, !Task.isCancelled else { return }
            result = DataSet(window: window, sleep: records,
                             vitals: readings.0.filter { $0.side == side.rawValue && $0.date >= window.start && $0.date < window.end }.sorted { $0.date < $1.date },
                             movement: readings.1.filter { $0.side == side.rawValue && $0.date >= window.start && $0.date < window.end }.sorted { $0.date < $1.date })
        } catch {
            guard selectedRevision == revision, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if selectedRevision == revision { loading = false }
    }
}
