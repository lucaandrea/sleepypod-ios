import SwiftUI

/// Task lifetime follows the visible screen; leaving it cancels periodic authorization checks.
struct PersonalHistoryAccessCheck: ViewModifier {
    let model: PersonalHistoryWorkspace
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content.task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                await model.checkAccess()
            }
        }
    }
}
