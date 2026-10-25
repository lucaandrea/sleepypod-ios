import Foundation
import Observation

@MainActor @Observable
final class BiometricsWorkspace {
    var vitals: [VitalsRecord] = []
    var movement: [MovementRecord] = []
    var sleep: [SleepRecord] = []
    var plots: [BiometricMetric: BiometricPlot] = [:]
    var sessions: [BiometricSession] = []
    var movementIntervals: [ClosedRange<Date>] = []
    var referenceIntervals: [ClosedRange<Date>] = []
    var error: String?
    var loading = false
    var reference = WatchReferenceData()
    var referencePlots: [BiometricMetric: BiometricPlot] = [:]
    var referenceError: String?
    var loadingReference = false
    var movementBuckets: [MovementBucket] = []
    var contextError: String?
    var liveStatus: BiometricsLiveStatus?
    var liveError: String?
    private let api: any SleepypodProtocol
    private let referenceAPI: (any WatchReferenceClient)?
    private let contextAPI: (any BiometricsContextClient)?
    private var revision = 0
    private var referenceRevision = 0
    private var liveRevision = 0
    private var liveSide: Side?
    private struct Query: Equatable { let side: Side; let window: DateInterval }
    private var query: Query?
    private var referenceQuery: Query?
    init(api: any SleepypodProtocol, referenceAPI: (any WatchReferenceClient)? = nil, contextAPI: (any BiometricsContextClient)? = nil) { self.api = api; self.referenceAPI = referenceAPI; self.contextAPI = contextAPI }
    func load(side: Side, window: DateInterval) async {
        revision += 1
        let nextQuery = Query(side: side, window: window)
        referenceRevision += 1; loadingReference = false
        // Keep a same-range refresh visually stable; a new person or interval must never show the previous query's data.
        if query != nextQuery {
            vitals = []; movement = []; sleep = []; plots = [:]; sessions = []; movementIntervals = []; referenceIntervals = []
            reference = WatchReferenceData(); referencePlots = [:]; referenceError = nil; referenceQuery = nil
            movementBuckets = []; contextError = nil
        }
        query = nextQuery
        let selectedRevision = revision
        loading = true; error = nil
        do {
            async let readings = api.getVitals(side: side, start: window.start, end: window.end)
            async let changes = api.getMovement(side: side, start: window.start, end: window.end)
            async let nights = api.getSleepRecords(side: side, start: window.start, end: window.end)
            let result = try await (readings, changes, nights)
            guard revision == selectedRevision, !Task.isCancelled else { return }
            vitals = result.0.filter { $0.side == side.rawValue && $0.date >= window.start && $0.date < window.end }.sorted { $0.date < $1.date }
            movement = result.1.filter { $0.side == side.rawValue && $0.date >= window.start && $0.date < window.end }.sorted { $0.date < $1.date }
            sleep = result.2.filter { $0.side == side.rawValue && $0.enteredBedDate >= window.start && $0.enteredBedDate < window.end }.sorted { $0.enteredBedDate > $1.enteredBedDate }
            plots = Dictionary(uniqueKeysWithValues: BiometricMetric.allCases.map { ($0, BiometricPlot(metric: $0, records: vitals)) })
            sessions = BiometricSession.split(vitals)
            if contextAPI == nil { movementIntervals = BiometricTimeAxis.intervals(dates: movement.map(\.date)) }
        } catch {
            guard revision == selectedRevision else { return }
            self.error = error.localizedDescription; vitals = []; movement = []; sleep = []; plots = [:]; sessions = []; movementIntervals = []
        }
        if revision == selectedRevision { loading = false }
    }
    func loadMovement(side: Side, window: DateInterval) async {
        guard let contextAPI else { return }
        let selectedRevision = revision
        do {
            let result = try await contextAPI.movement(side: side, window: window)
            guard selectedRevision == revision, !Task.isCancelled else { return }
            movementBuckets = result; contextError = nil
            movementIntervals = BiometricTimeAxis.intervals(dates: result.compactMap(\.date), sampleDuration: 300)
        } catch { guard selectedRevision == revision, !Task.isCancelled else { return }; contextError = error.localizedDescription }
    }
    func loadLive(side: Side) async {
        guard let contextAPI else { return }
        if liveSide != side { liveStatus = nil; liveError = nil; liveSide = side }
        liveRevision += 1; let selectedRevision = liveRevision
        do {
            let result = try await contextAPI.live(side: side)
            guard selectedRevision == liveRevision, !Task.isCancelled else { return }
            liveStatus = result; liveError = nil
        } catch { guard selectedRevision == liveRevision, !Task.isCancelled else { return }; liveStatus = nil; liveError = error.localizedDescription }
    }
    func loadReference(side: Side, window: DateInterval) async {
        guard let referenceAPI else { return }
        referenceRevision += 1
        let selectedReferenceRevision = referenceRevision
        let selectedRevision = revision
        loadingReference = true; referenceError = nil
        let nextQuery = Query(side: side, window: window)
        if referenceQuery != nextQuery { reference = WatchReferenceData(); referencePlots = [:]; referenceIntervals = [] }
        referenceQuery = nextQuery
        do {
            let result = try await referenceAPI.load(side: side, window: window)
            guard selectedRevision == revision, selectedReferenceRevision == referenceRevision, !Task.isCancelled else { return }
            reference = result
            referenceIntervals = BiometricTimeAxis.intervals(dates: BiometricMetric.allCases.flatMap { result.readings($0).map(\.date) })
            referencePlots = Dictionary(uniqueKeysWithValues: BiometricMetric.allCases.map { metric in
                let records = result.readings(metric).enumerated().map { VitalsRecord(id: $0.offset, heartRate: $0.element.value, date: $0.element.date) }
                return (metric, BiometricPlot(metric: .heartRate, records: records))
            })
        } catch {
            guard selectedRevision == revision, selectedReferenceRevision == referenceRevision, !Task.isCancelled else { return }
            referenceError = error.localizedDescription
        }
        if selectedRevision == revision && selectedReferenceRevision == referenceRevision { loadingReference = false }
    }
}
