import SwiftUI

struct MorningJournalContextEditor: View {
    @Binding var draft: MorningJournalContextDraft
    let wakeDate: String
    let timeZone: String
    let focus: FocusState<String?>.Binding
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A little context, if you remember").font(.headline)
            Text("Everything here is optional. Not logged means unknown; None means you remember having none.")
                .font(.footnote).foregroundStyle(Theme.text2)
            habit("Caffeine", identifier: "caffeine", amount: "Total caffeine (mg)", time: "Last caffeine", value: $draft.caffeine)
            Divider()
            habit("Alcohol", identifier: "alcohol", amount: "US standard drinks", time: "Last drink", value: $draft.alcohol)
            if draft.alcohol.status == "yes" {
                Text("One US standard drink contains 14 g of pure alcohol. Your drink may contain more than one.").font(.caption).foregroundStyle(Theme.text2)
            }
            Divider()
            habit("Exercise", identifier: "exercise", amount: "Exercise minutes", time: "Exercise finished", value: $draft.exercise)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 18) {
                    MorningJournalTimeField(title: "Reported bedtime", identifier: "bedtime", wakeDate: wakeDate, timeZone: timeZone, suggestedHour: 22, value: $draft.bedtime)
                    MorningJournalTimeField(title: "Last meal", identifier: "meal", wakeDate: wakeDate, timeZone: timeZone, suggestedHour: 19, value: $draft.meal)
                    Text("Stress compared with your usual day").font(.subheadline)
                    Picker("Stress compared with your usual day", selection: $draft.stress) {
                        Text("Not logged").tag("not_logged"); Text("Lower").tag("lower")
                        Text("Usual").tag("usual"); Text("Higher").tag("higher")
                    }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("journal.context.stress")
                }.padding(.top, 12)
            } label: {
                Text("Bedtime, meal and stress context").accessibilityIdentifier("journal.context.details")
            }
            Text("Times use \(timeZone). Details stay on your Pod and do not change the bed or go to an AI provider.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
    }
    private func habit(_ title: String, identifier: String, amount: String, time: String, value: Binding<MorningJournalContextDraft.Habit>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.semibold))
            Picker(title, selection: value.status) {
                Text("Not logged").tag("not_logged"); Text("None").tag("none"); Text("Yes").tag("yes")
            }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("journal.context.\(identifier).status")
            if value.wrappedValue.status == "yes" {
                VStack(alignment: .leading, spacing: 6) {
                    Text(amount).font(.subheadline)
                    // Keep invalid/unfinished text as a draft; blank and a reported zero are distinct.
                    TextField(amount, text: value.amount, prompt: Text("Unknown").foregroundStyle(Theme.text2)).keyboardType(.decimalPad)
                        .focused(focus, equals: identifier).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(amount).accessibilityIdentifier("journal.context.\(identifier).amount")
                }
                MorningJournalTimeField(title: time, identifier: identifier, wakeDate: wakeDate, timeZone: timeZone, suggestedHour: 12, value: value.time)
            }
        }
    }
}
