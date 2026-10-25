import SwiftUI

struct AutopilotView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
            SleepPage(title: "A night that learns.", subtitle: "Small, explainable adjustments. Your routine stays in charge.") {
                SidePicker().frame(maxWidth: 350)
                ComfortCard().id(model.side)
                SleepCard(title: "Understand your nights", eyebrow: "PERSONAL INTELLIGENCE") {
                    Text("Review your Health history and comfort feedback with your chosen model. Suggestions remain separate from bed controls.")
                        .foregroundStyle(SleepTheme.secondary)
                    NavigationLink("Personal reports & models") { IntelligenceView() }.buttonStyle(SleepButtonStyle())
                    NavigationLink("Explore a sleep question") { CoachView() }.buttonStyle(SleepButtonStyle())
                }
                SleepCard(title: "Your routine", eyebrow: "THE FOUNDATION") {
                    Text("Set the timing and temperatures that personal comfort learns from.").foregroundStyle(SleepTheme.secondary)
                    NavigationLink("Edit routines & wake alarms") { RoutinesView() }.buttonStyle(SleepButtonStyle())
                }
            }
        }
    }
}
