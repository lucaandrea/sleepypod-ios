import Foundation
import Observation

/// Shared by native routes; changing controller/credentials discards the previous inbox and cursor.
@MainActor @Observable final class AlertInboxSession {
    private var scope: String?
    private(set) var workspace: AlertInboxWorkspace?
    private(set) var setupError: String?
    func configure(scope: String, client: (any AlertInboxServing)?) {
        guard self.scope != scope else { return }
        self.scope = scope; workspace?.isActive = false; workspace = nil; setupError = nil
        if let client { workspace = .init(client: client) }
        else { setupError = "Connect to a Sleepypod Core controller to read its automation alerts." }
    }
    func configure(scope: String) {
        guard self.scope != scope else { return }
        if APIBackend.current.isDemo { configure(scope: scope, client: DemoAlertInboxClient()); return }
        guard APIBackend.current == .sleepypodCore, let transport = try? CoreRESTClient.configured() else {
            configure(scope: scope, client: nil); return
        }
        configure(scope: scope, client: CoreAlertInboxClient(transport: transport))
    }
}
