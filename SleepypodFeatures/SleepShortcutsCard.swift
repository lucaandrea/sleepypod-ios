import SwiftUI
import AppIntents

/// Useful compositions of the app's real actions, with direct access to its Shortcuts library.
struct SleepShortcutsCard: View {
    var body: some View {
        GroupedSection("SLEEP SHORTCUTS") {
            GroupedCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your night, in a few words").font(.title3.weight(.semibold))
                    Text("Ask Siri for your next bed alarm, change it for tomorrow, skip it once, or check your recent nights.")
                        .font(.subheadline).foregroundStyle(Theme.text2)
                    ShortcutsLink().shortcutsLinkStyle(.automatic).accessibilityIdentifier("shortcuts.library")
                    Label("“When is my next bed alarm in sleepypod?”", systemImage: "mic")
                        .font(.subheadline).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }.padding(16)
            }
            GroupedCard {
                recipe("Wind down", icon: "moon", detail: "Use your Sleep Focus or a chosen bedtime as the trigger. Add Set bed power, Set bed temperature, and Get next bed alarm. Choose your side and target; optionally run an existing Home scene.")
                recipe("Tomorrow starts earlier", icon: "alarm", detail: "Add Change next bed alarm and supply the new time in 24-hour HH:mm. Ask for the time each run, or calculate it from your first Calendar event. Only the upcoming alarm changes; the weekly routine stays intact.")
                recipe("Sleep in once", icon: "alarm.slash", detail: "Use Skip next bed alarm for a day off. Restore bed alarm routine removes the one-time skip when your plans change.")
                recipe("Morning check-in", icon: "sun.max", detail: "Combine Get sleep routine summary, Sync Apple Health, and Get bed temperature. Use Speak Text or Show Result to hear or read the returned values. Health access follows your choices in the app.")
                recipe("A cooler night", icon: "thermometer.snowflake", detail: "Read the target with Get bed temperature, subtract your preferred number of degrees in Calculate, then pass the result to Set bed temperature. Choose a whole Fahrenheit target from 55 to 110.")
                recipe("Read, then rest", icon: "book", detail: "Add Set bed position with the Read preset to your reading Shortcut. Use the Sleep or Flat preset when you finish. Stop bed is a separate action you can keep within easy reach.")
            }.accessibilityIdentifier("shortcuts.recipes")
            Text("These are recipes to build in Shortcuts. The actions are available now; triggers and combined workflows run only after you configure them. Your Pod must be reachable. Bed motion requires a connected adjustable base.")
                .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16).fixedSize(horizontal: false, vertical: true)
            GroupedCard {
                DisclosureGroup("All available actions") {
                    Text("Temperature: read current or target; set target.\nBed: power, presets, head and feet angles, stop.\nAlarms: read, change, skip, restore, dismiss.\nSleep: routine summary, Health sync, adaptive comfort preview.\nMaintenance: Away mode and priming.")
                        .font(.subheadline).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                }.padding(16)
            }
        }
    }

    private func recipe(_ title: String, icon: String, detail: String) -> some View {
        DisclosureGroup {
            Text(detail).font(.subheadline).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        } label: { Label(title, systemImage: icon) }
        .padding(16)
    }
}
