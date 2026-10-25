import BackgroundTasks
import Foundation

@MainActor
enum HealthBackgroundScheduler {
    static let identifier = "com.lucaandrea.freesleep.health.refresh"
    static func schedule(settings: HealthSyncSettings?) throws {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard !AppMode.isDemo, let settings, settings.automatic, settings.lastSuccess != nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        try BGTaskScheduler.shared.submit(request)
    }
}
