import SwiftUI

struct MorningJournalTimeField: View {
    let title: String
    let identifier: String
    let wakeDate: String
    let timeZone: String
    let suggestedHour: Int
    @Binding var value: MorningJournalContextDraft.Time
    private var clock: Binding<Date> {
        Binding(get: { MorningJournalContextClock.floatingDate(value.wall) ?? proposedClock }, set: {
            value.wall = MorningJournalContextClock.wallTime($0.timeIntervalSince1970 * 1000, timeZone: "GMT")
            value.occurrence = nil
        })
    }
    private var proposedClock: Date {
        let date = MorningJournalDates.shift(wakeDate, days: -1) ?? wakeDate
        return MorningJournalContextClock.floatingDate(String(format: "%@T%02d:00", date, suggestedHour)) ?? .now
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline)
            if value.wall.isEmpty {
                Button("Add date and time", systemImage: "clock") {
                    value.wall = MorningJournalContextClock.wallTime(proposedClock.timeIntervalSince1970 * 1000, timeZone: "GMT")
                    value.occurrence = nil
                }.accessibilityLabel("Add \(title.lowercased())").accessibilityIdentifier("journal.context.\(identifier).add")
            } else {
                DatePicker(title, selection: clock, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().environment(\.timeZone, .gmt).environment(\.calendar, Calendar(identifier: .gregorian))
                    .accessibilityLabel("\(title), entry clock in \(timeZone)")
                    .accessibilityIdentifier("journal.context.\(identifier).clock")
                let candidates = MorningJournalContextClock.candidates(value.wall, timeZone: timeZone)
                if candidates.count > 1 {
                    Text("This clock time occurs twice. Which occurrence?").font(.footnote)
                    Menu {
                        Picker("\(title) clock occurrence", selection: $value.occurrence) {
                            Text("Choose occurrence").tag(Double?.none)
                            ForEach(candidates, id: \.self) { instant in
                                Text(instant == candidates.first ? "Earlier occurrence" : "Later occurrence").tag(Optional(instant))
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(value.occurrence == nil ? "Choose occurrence" : value.occurrence == candidates.first ? "Earlier occurrence" : "Later occurrence")
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true)
                        }.frame(minHeight: 44).contentShape(.rect)
                    }.accessibilityIdentifier("journal.context.\(identifier).occurrence")
                }
                Text("Review the date and time before saving.").font(.caption).foregroundStyle(Theme.text2)
                Button("Remove time") { value.wall = ""; value.occurrence = nil }
                    .font(.subheadline).accessibilityLabel("Remove \(title.lowercased())").accessibilityIdentifier("journal.context.\(identifier).remove")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
