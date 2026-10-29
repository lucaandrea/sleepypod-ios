import SwiftUI

struct HouseholdPreparationEntry: View {
    @Environment(HouseholdWorkspace.self) private var model
    @State private var checking = true
    var body: some View {
        Form {
            Section {
                Label("Personal profiles", systemImage: "person.2").font(.headline)
                Text("Each person can prepare their own preferences and weekly drafts on their own device. Joining does not assign a bed side, activate routines or import Health data.")
                if checking { ProgressView("Checking controller…") }
                else if !model.ownerSetupReady {
                    Text("Preparation is not enabled on this controller.").foregroundStyle(Theme.amber)
                }
            }
            Section {
                Button("Open personal preparation") { model.enter() }.disabled(checking || !model.ownerSetupReady)
                Button("I have an invitation") { model.enter() }
                Text("The personal workspace replaces the owner controls while open. Returning to a retained owner connection requires this device’s owner authentication.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
        }.scrollContentBackground(.hidden).background(Theme.background).navigationTitle("Personal profiles")
            .task { await model.checkOwnerPreparation(); checking = false }
    }
}
