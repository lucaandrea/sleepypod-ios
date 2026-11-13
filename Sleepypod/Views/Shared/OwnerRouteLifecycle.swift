import SwiftUI
import FreeSleepKit

/// Foreground recovery only selects a verified transport; all managers discard old requests and drafts.
struct OwnerRouteLifecycle: ViewModifier {
    @Environment(OwnerRouteSession.self) private var routes
    @Environment(DeviceManager.self) private var device
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedules
    @Environment(MetricsManager.self) private var metrics
    @Environment(StatusManager.self) private var status
    @Environment(SensorStreamService.self) private var stream
    @Environment(\.scenePhase) private var phase
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("ownerConnectionRevision") private var owner = ""
    @AppStorage("household.boundaryRevision") private var boundary = ""
    @State private var path = ConnectionPathMonitor()
    @State private var pathRevision = UUID()
    private var scope: String { "\(phase)|\(backend)|\(endpoint)|\(owner)|\(boundary)|\(pathRevision)|\(routes.change)|\(routes.editing)" }

    func body(content: Content) -> some View {
        content
            .task(id: "\(phase)|\(backend)|\(boundary)") {
                guard phase == .active, APIBackend.current == .sleepypodCore, !PersonalWorkspaceBoundary.isActive else { path.stop(); return }
                path.start(onPermission: { _ in }) { pathRevision = UUID() }
            }
            .task(id: scope) {
                guard phase == .active, APIBackend.current == .sleepypodCore, !PersonalWorkspaceBoundary.isActive else {
                    routes.invalidate(); return
                }
                guard !routes.editing else { return }
                routes.invalidate()
                repeat {
                    await routes.resolve(activate: activate)
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                } while !Task.isCancelled
            }
            .onDisappear { path.stop(); routes.invalidate() }
    }

    private func activate(_ candidate: OwnerConnectionCandidate) throws {
        guard phase == .active, !PersonalWorkspaceBoundary.isActive, APIBackend.current == .sleepypodCore else {
            throw ControllerIdentityFailure.changedCredentials
        }
        try UnifiedRuntime.useSavedConnection(address: candidate.endpoint.absoluteString, token: candidate.token)
        UserDefaults.standard.set(candidate.streamAddress, forKey: "podStreamURL")
        settings.podIP = candidate.endpoint.host ?? ""
        stream.disconnect()
        let client = APIBackend.sleepypodCore.createClient()
        device.switchBackend(client); settings.switchBackend(client); schedules.switchBackend(client)
        metrics.switchBackend(client); status.switchBackend(client)
    }
}
