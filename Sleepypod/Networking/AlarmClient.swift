import Foundation

protocol AlarmClient: Sendable {
    func all() async throws -> [CoreAlarmRow]
    func apply(_ batch: AlarmBatch) async throws
    func test(_ job: AlarmJob) async throws
    func stop(_ side: Side) async throws
    func supportsSnooze() async -> Bool
}
extension AlarmClient { func supportsSnooze() async -> Bool { false } }

struct CoreAlarmClient: AlarmClient {
    var client: CoreRESTClient?
    private func connection() throws -> CoreRESTClient { try client ?? .configured() }
    func all() async throws -> [CoreAlarmRow] {
        let connection = try connection()
        async let left: CoreScheduleRows = connection.get("schedules", query: ["side": "left", "unit": "F"])
        async let right: CoreScheduleRows = connection.get("schedules", query: ["side": "right", "unit": "F"])
        return try await left.alarm + right.alarm
    }
    func apply(_ batch: AlarmBatch) async throws { try await connection().post("schedules/batch", body: batch) }
    func test(_ job: AlarmJob) async throws { try await connection().post("device/alarm", body: job) }
    func stop(_ side: Side) async throws { try await connection().post("device/alarm/clear", body: ["side": side.rawValue]) }
    func supportsSnooze() async -> Bool {
        guard let schema: CoreAPIDocument = try? await connection().get("openapi.json") else { return false }
        return schema.accepts("snoozeDuration", path: "/schedules/alarm", method: "post")
            && schema.accepts("snoozeTaper", path: "/schedules/alarm", method: "post")
    }
}

actor DemoAlarmClient: AlarmClient {
    private var rows: [CoreAlarmRow]
    private var nextID = 100
    init() {
        var draft = AlarmDraft(sides: [.left, .right]); draft.days = Set(DayOfWeek.allCases); draft.temperature = 78
        rows = draft.creates.enumerated().map { $0.element.row(id: $0.offset + 1) }
    }
    func all() -> [CoreAlarmRow] { rows }
    func apply(_ batch: AlarmBatch) {
        rows.removeAll { batch.deletes.contains($0.id) }
        for update in batch.updates {
            if let index = rows.firstIndex(where: { $0.id == update.id }) { rows[index].enabled = update.enabled }
        }
        for create in batch.creates { rows.append(create.row(id: nextID)); nextID += 1 }
    }
    func test(_ job: AlarmJob) {}
    func stop(_ side: Side) {}
}
