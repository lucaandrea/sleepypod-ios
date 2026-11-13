import SwiftUI

struct PersonalRouteLifecycle: ViewModifier {
    @Environment(HouseholdWorkspace.self) private var household
    @Environment(\.scenePhase) private var phase
    @State private var path = ConnectionPathMonitor()
    @State private var revision = UUID()
    private var scope: String {
        "\(phase)|\(household.active)|\(household.selected?.id.uuidString ?? "")|\(household.routes.editing)|\(household.selected?.verifiedRoutes?.enabled == true)|\(revision)"
    }
    func body(content: Content) -> some View {
        content.task(id: scope) {
            path.stop()
            guard phase == .active, household.active, !household.routes.editing,
                  household.selected?.verifiedRoutes?.enabled == true else { return }
            path.start(onPermission: { _ in }) { revision = UUID() }
            repeat {
                await household.checkPersonalConnection()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        .onDisappear { path.stop(); household.routes.invalidate() }
    }
}
