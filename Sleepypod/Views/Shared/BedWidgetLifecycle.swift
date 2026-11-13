import SwiftUI

struct BedWidgetLifecycle: ViewModifier {
    let session: BedWidgetSession
    let accountContext: [String]
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ownerConnectionRevision") private var owner = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("household.boundaryRevision") private var boundary = ""
    private var context: [String] { accountContext + [owner, backend, endpoint, host, boundary] }

    func body(content: Content) -> some View {
        content
            .onChange(of: context) { session.withdraw() }
            .task(id: context + [String(describing: scenePhase)]) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await session.refresh()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
            .onOpenURL { url in
                guard BedWidgetRoute.accepts(url) else { return }
                NotificationCenter.default.post(name: .openBedWidget, object: nil)
            }
    }
}

extension Notification.Name {
    static let openBedWidget = Notification.Name("sleepypod.openBedWidget")
}
