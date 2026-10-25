import SwiftUI

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
        SleepPage(title: "Make it yours.", narrow: true) {
            SleepCard(title: "Pod connection") {
                Text("Manage the controller address, owner key and backend in More → Pod connection.")
                    .foregroundStyle(SleepTheme.secondary)
            }
            SleepCard(title: "Routines & wake alarms") {
                NavigationLink("Edit your routines") { RoutinesView() }.buttonStyle(SleepButtonStyle())
            }
            HealthConnectionCard()
            SleepCard(title: "AI & personal history", eyebrow: "YOUR MODELS") {
                Text("Choose Apple Intelligence, OpenAI, Gemini, Claude or your local Gemma server. Save your own API keys privately on this device.").foregroundStyle(SleepTheme.secondary)
                NavigationLink("Model settings & Health history") { IntelligenceView() }.buttonStyle(SleepButtonStyle())
            }
            SleepCard(title: "Shortcuts & Siri", eyebrow: "EVERYDAY ACTIONS") {
                Text("Find Free Sleep in Shortcuts on your iPhone to control temperature, power, bed position, adaptive comfort and Away mode; change or skip your next alarm, sync Health, or read your latest summary.")
                    .foregroundStyle(SleepTheme.secondary)
                Text("Bed movement affects both sides. Your iPhone must be able to reach the Pod or your secure gateway.")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            }
            SleepCard(title: "Fine-tune your setup") {
                NavigationLink("Device settings") { DevicePreferencesView() }.buttonStyle(SleepButtonStyle())
                NavigationLink("System health") { SystemHealthView() }.buttonStyle(SleepButtonStyle())
            }
        }
        }
    }
}
