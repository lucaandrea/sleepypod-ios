import Foundation
import Observation

@MainActor
@Observable
final class MetricsManager {
    var sleepRecords: [SleepRecord] = []
    var vitalsRecords: [VitalsRecord] = []
    var vitalsSummary: VitalsSummary?
    var movementRecords: [MovementRecord] = []
    var selectedSide: Side = .left
    var selectedWeekStart: Date = Calendar.current.startOfWeek(for: Date())
    var timeZone = "America/Los_Angeles"
    var calendar: Calendar { SleepCalendar.calendar(timeZone: timeZone) }
    var isLoading = false
    var isSaving = false
    var mutationError: String?
    var notice: String?
    var error: String?

    private var api: SleepypodProtocol

    init(api: SleepypodProtocol) {
        self.api = api
    }

    func switchBackend(_ client: SleepypodProtocol) {
        requestGeneration += 1; connectionRevision += 1; api = client
        sleepRecords = []; vitalsRecords = []; movementRecords = []; vitalsSummary = nil
        error = nil; mutationError = nil; notice = nil; isLoading = false
    }

    // MARK: - Computed

    var selectedWeekEnd: Date {
        calendar.date(byAdding: .day, value: 7, to: selectedWeekStart) ?? selectedWeekStart
    }

    var weekLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        formatter.timeZone = calendar.timeZone
        let start = formatter.string(from: selectedWeekStart)
        let end = formatter.string(from: calendar.date(byAdding: .day, value: 6, to: selectedWeekStart) ?? selectedWeekStart)
        return "\(start) - \(end)"
    }

    var selectedDayRecord: SleepRecord? {
        sleepRecords.first
    }

    var averageSleepHours: Double {
        guard !sleepRecords.isEmpty else { return 0 }
        return sleepRecords.reduce(0.0) { $0 + $1.durationHours } / Double(sleepRecords.count)
    }

    var totalMovement: Int {
        movementRecords.reduce(0) { $0 + $1.totalMovement }
    }

    // MARK: - Navigation

    func previousWeek() {
        selectedWeekStart = calendar.date(byAdding: .day, value: -7, to: selectedWeekStart) ?? selectedWeekStart
        Task { await fetchAll() }
    }

    func nextWeek() {
        let next = calendar.date(byAdding: .day, value: 7, to: selectedWeekStart) ?? selectedWeekStart
        guard next <= Date() else { return }
        selectedWeekStart = next
        Task { await fetchAll() }
    }

    // MARK: - Fetch

    private var requestGeneration = 0
    private var connectionRevision = 0

    func fetchAll() async {
        requestGeneration += 1
        let generation = requestGeneration
        let side = selectedSide
        let start = selectedWeekStart
        // Include the morning following the last bedtime in this week.
        let end = calendar.date(byAdding: .hour, value: 12, to: selectedWeekEnd) ?? selectedWeekEnd
        let client = api
        isLoading = true
        error = nil
        do {
            async let sleep = client.getSleepRecords(side: side, start: start, end: end)
            async let vitals = client.getVitals(side: side, start: start, end: end)
            async let movement = client.getMovement(side: side, start: start, end: end)
            async let summary = client.getVitalsSummary(side: side, start: start, end: end)
            let result = try await (sleep, vitals, movement, summary)
            guard generation == requestGeneration, side == selectedSide, start == selectedWeekStart else { return }
            sleepRecords = result.0.filter { $0.side == side.rawValue && SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar) >= start && SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar) < selectedWeekEnd }
                .sorted { $0.enteredBedDate > $1.enteredBedDate }
            vitalsRecords = result.1.filter { $0.side == side.rawValue }
            movementRecords = result.2.filter { $0.side == side.rawValue }
            vitalsSummary = result.3
        } catch {
            guard generation == requestGeneration else { return }
            self.error = error.localizedDescription
            sleepRecords = []; vitalsRecords = []; movementRecords = []; vitalsSummary = nil
        }
        if generation == requestGeneration { isLoading = false }
    }

    // Check the times again before an edit so a stale sheet cannot overwrite another device's correction.
    func change(_ draft: SleepRecordDraft, deleting: Bool = false) async -> Bool {
        guard !isSaving else { return false }
        if !deleting, let validation = draft.validation { mutationError = validation; return false }
        let revision = connectionRevision
        let client = api
        let original = draft.original
        guard let side = Side(rawValue: original.side) else { return false }
        isSaving = true; mutationError = nil; notice = nil
        defer { isSaving = false }
        do {
            let fresh = try await client.getSleepRecords(side: side, start: original.enteredBedDate.addingTimeInterval(-1), end: original.enteredBedDate.addingTimeInterval(1))
            guard revision == connectionRevision else { return false }
            guard let current = fresh.first(where: { $0.id == original.id }),
                  current.enteredBedDate == original.enteredBedDate, current.completedAt == original.completedAt else {
                mutationError = "This record changed on another device. Close this editor and reload before editing."; return false
            }
            if deleting { try await client.deleteSleepRecord(id: original.id) }
            else { try await client.updateSleepRecord(id: original.id, enteredBedAt: draft.bedtime, leftBedAt: draft.wake) }
            guard revision == connectionRevision else { return false }
            await fetchAll()
            notice = error == nil ? (deleting ? "Sleep record deleted." : "Sleep times saved.")
                : "Your change was saved, but the updated records could not be loaded. Pull to refresh."
            return true
        } catch {
            guard revision == connectionRevision else { return false }
            mutationError = error.localizedDescription; return false
        }
    }

}

// MARK: - Calendar Extension

extension Calendar {
    /// Weeks start on Monday, matching the M–S day chips and week bars.
    func startOfWeek(for date: Date) -> Date {
        var calendar = self
        calendar.firstWeekday = 2
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? date
    }
}
