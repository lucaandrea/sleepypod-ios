import SwiftUI

struct ExampleAlertInboxScreen: View {
    @State private var session = AlertInboxSession()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        AlertInboxScreen(example: true).environment(session)
            .task(id: scenePhase) {
                session.configure(scope: "explicit-synthetic-example", client: ExampleAlertInboxClient())
                guard let model = session.workspace else { return }
                model.isActive = scenePhase == .active
                guard model.isActive else { return }
                while !Task.isCancelled {
                    await model.refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }
}
