import SwiftUI

struct LegacyBaseScreen: View {
    @Environment(AppModel.self) private var model
    @State private var head = 0.0
    @State private var feet = 0.0
    private var fresh: Bool {
        guard let base = model.base, let timestamp = base.updatedAt else { return false }
        let age = Date().timeIntervalSince1970 - timestamp / 1000
        return !base.stale && age >= 0 && age < 15
    }
    private var reported: String {
        guard fresh, let position = model.base?.position else { return "Position unavailable" }
        return "Head \(Int(position.left.head))° · feet \(Int(position.left.feet))°"
    }
    var body: some View {
        BedPositionPanel(head: $head, feet: $feet, reported: reported,
                         ready: fresh && model.base?.ready == true, moving: model.acting,
                         stopping: model.stopping, demo: model.demo,
                         message: model.demo ? "Demo preview · no hardware commands" : model.actionMessage,
                         move: { guard fresh, model.base?.ready == true else { return }; Task { await model.moveBase(head: head, feet: feet) } },
                         stop: { Task { await model.stopBase() } },
                         reconnect: { Task { await model.connectBase() } })
    }
}
