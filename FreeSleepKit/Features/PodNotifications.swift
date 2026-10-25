import SwiftUI

struct PodNotifications: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.device?[model.side].isAlarmVibrating == true {
            SleepCard(title: "Your alarm is vibrating.") {
                Button("Dismiss alarm") { Task { await model.dismissAlarm() } }.buttonStyle(SleepButtonStyle(kind: .primary)).disabled(model.acting)
            }
        }
        if model.device?.isPriming == true { Label("Your Pod is priming.", systemImage: "drop.circle").sleepText(.body) }
        if model.device?.waterLevel == "false" { Label("Refill your Pod’s water tank.", systemImage: "drop.triangle").foregroundStyle(.orange) }
        if model.settings?[model.side].awayMode == true {
            Label("This side is in away mode, temperature control unavailable.", systemImage: "suitcase").sleepText(.body)
        } else if model.settings?[model.side == .left ? .right : .left].awayMode == true {
            Label("Other side is in away mode, temperature settings will apply to both sides.", systemImage: "suitcase").sleepText(.body)
        }
    }
}
