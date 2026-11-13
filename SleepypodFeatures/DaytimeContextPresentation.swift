import Foundation

enum DaytimeContextPresentation {
    @MainActor static func exampleNotice() -> String? {
        #if DEBUG
        return AppMode.isDemo && UserDefaults.standard.string(forKey: "uiDaytimeContext") == "unreadable"
            ? DaytimeContextWorkspace.unreadableArchiveMessage : nil
        #else
        return nil
        #endif
    }
    @MainActor static func example() -> DaytimeContextArchive {
        guard AppMode.isDemo else { return .init() }
        #if DEBUG
        let scenario = UserDefaults.standard.string(forKey: "uiDaytimeContext") ?? "off"
        guard scenario != "off", scenario != "unreadable" else { return .init() }
        let end = Date.now.addingTimeInterval(-60)
        let source = DaytimeContext.Source(identifier: "example-watch", name: "Example Watch", device: "Watch")
        let observations: [DaytimeContext.Observation] = scenario == "available" ? [
            .init(id: UUID(), kind: .workout, source: source, start: end.addingTimeInterval(-7200), end: end.addingTimeInterval(-4500), value: 45, workoutActivity: 37),
            .init(id: UUID(), kind: .steps, source: source, start: end.addingTimeInterval(-10_000), end: end.addingTimeInterval(-9000), value: 2400),
            .init(id: UUID(), kind: .steps, source: .init(identifier: "example-phone", name: "Example Phone", device: "Phone"),
                  start: end.addingTimeInterval(-10_000), end: end.addingTimeInterval(-9000), value: 1800),
            .init(id: UUID(), kind: .sleepingWristCelsius, source: source, start: end.addingTimeInterval(-86_400), end: end.addingTimeInterval(-57_600), value: 34.2)
        ] : []
        return .init(enabled: true, snapshot: .init(importedAt: end, timeZone: "America/Los_Angeles", reads: DaytimeContext.Kind.allCases.map {
            .init(kind: $0, state: scenario == "unavailable" ? .unavailable : .completed, start: end.addingTimeInterval(-90 * 86_400), end: end)
        }, observations: observations))
        #else
        return .init()
        #endif
    }
}
