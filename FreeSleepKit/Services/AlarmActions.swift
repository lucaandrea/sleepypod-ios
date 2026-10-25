import Foundation

extension PodActions {
    static func nextAlarm(side: BedSide) async throws -> AlarmPreview {
        let preview: AlarmPreview = try await client().get("alarm/next", query: [URLQueryItem(name: "side", value: side.rawValue)])
        return try matching(preview, side: side)
    }

    static func changeAlarm(side: BedSide, action: AlarmChange.Action, time: String? = nil) async throws -> AlarmPreview {
        let client = try client()
        let preview: AlarmPreview = try await client.get("alarm/next", query: [URLQueryItem(name: "side", value: side.rawValue)])
        let change = try AlarmChange.validated(preview: matching(preview, side: side), action: action, time: time)
        let saved: AlarmPreview = try await client.postReturning("alarm/override", body: change)
        return try matching(saved, side: side)
    }
    private static func matching(_ preview: AlarmPreview, side: BedSide) throws -> AlarmPreview {
        guard preview.side == side else { throw PodError.message("The Pod returned an alarm for a different side. Check the connection and try again.") }
        return preview
    }
}

extension AlarmChange {
    // Shortcuts fetches one occurrence before editing it; the server rejects it if it changes in flight.
    static func validated(preview: AlarmPreview, action: Action, time: String? = nil) throws -> AlarmChange {
        if action == .restore {
            guard preview.expiresAt != nil else { throw PodError.message("There is no one-time alarm change to restore.") }
        } else {
            guard preview.state == "scheduled", preview.alarm != nil else {
                throw PodError.message("No upcoming alarm is available to change. Check your routine and Away mode.")
            }
        }
        if action == .time {
            guard let time, time.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else {
                throw PodError.message("Enter a 24-hour time such as 07:30 or 21:15, in your Pod's timezone.")
            }
        }
        return .init(preview: preview, action: action, time: time)
    }
}
