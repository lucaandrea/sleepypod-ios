import SwiftUI

struct BedroomHomeView: View {
    var body: some View {
        NavigationStack {
            SleepPage(title: "A home ready for rest.", subtitle: "Bring your bed, room and existing Home scenes together.") {
                HomeConnectionCard()
                SleepCard(title: "Room context", eyebrow: "HOME ASSISTANT", badge: "Not connected") {
                    Text("Temperature, humidity, air quality and accessory controls will appear after the home server is connected. Missing readings never trigger bed adjustments.")
                        .foregroundStyle(SleepTheme.secondary)
                }
                SleepCard(title: "Build your evening", eyebrow: "AUTOMATION IDEAS") {
                    Label("Wind down · lighting and shades", systemImage: "sunset")
                    Label("Night path · gentle light after bed exit", systemImage: "lightbulb")
                    Label("Wake together · alarm, light and a Home scene", systemImage: "sunrise")
                    Text("These templates are not active. Each connection and action needs qualification before automatic use.")
                        .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                }
            }
        }
    }
}
