import Foundation
import Observation

@MainActor @Observable
final class RoutineWorkspace {
    var day = "monday"
    private(set) var drafts: [String: RoutineDraft] = [:]
    private(set) var demoBook: RoutineBook?
    init() {
        if let url = Bundle.main.url(forResource: "routines-demo", withExtension: "json"), let data = try? Data(contentsOf: url) {
            demoBook = try? JSONDecoder().decode(RoutineBook.self, from: data)
        }
    }
    func put(_ key: String, original: DailySchedule, value: DailySchedule, copies: Set<String>) {
        let baseline = drafts[key]?.original ?? original
        if baseline == value && copies.isEmpty { drafts[key] = nil }
        else { drafts[key] = .init(original: baseline, value: value, copies: copies) }
    }
    func clear(_ keys: [String]) { for key in keys { drafts[key] = nil } }
    func saveDemo(_ request: RoutineSave) throws -> RoutineBook {
        guard var book = demoBook else { throw PodError.message("The demo routines could not be loaded.") }
        try RoutinePlan.apply(request, to: &book); demoBook = book
        return book
    }
}
