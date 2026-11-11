import AlarmKit
import Foundation
import SwiftUI

private struct WakeBackupMetadata: AlarmMetadata {}

@MainActor struct SystemBackupAlarmClient: BackupAlarmClient {
    func requestAccess() async throws -> Bool {
        if AlarmManager.shared.authorizationState == .notDetermined {
            return try await AlarmManager.shared.requestAuthorization() == .authorized
        }
        return AlarmManager.shared.authorizationState == .authorized
    }
    func alarms() throws -> [BackupSystemAlarm] {
        try AlarmManager.shared.alarms.map { alarm in
            let at: Date? = if case .fixed(let date) = alarm.schedule { date } else { nil }
            let state: String = switch alarm.state {
            case .scheduled: "scheduled"
            case .alerting: "alerting"
            case .countdown: "countdown"
            case .paused: "paused"
            @unknown default: "unknown"
            }
            return .init(id: alarm.id, at: at, state: state)
        }
    }
    func schedule(id: UUID, at: Date) async throws {
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) { alert = .init(title: "Sleepypod wake-up") }
        else { alert = .init(title: "Sleepypod wake-up", stopButton: .init(text: "Stop", textColor: .white, systemImageName: "stop.fill")) }
        let attributes = AlarmAttributes(presentation: .init(alert: alert), metadata: WakeBackupMetadata(), tintColor: .blue)
        let configuration = AlarmManager.AlarmConfiguration<WakeBackupMetadata>(schedule: .fixed(at), attributes: attributes)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }
    func cancel(id: UUID) throws { try AlarmManager.shared.cancel(id: id) }
}
