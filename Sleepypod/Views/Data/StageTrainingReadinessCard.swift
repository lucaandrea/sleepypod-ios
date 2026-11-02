import SwiftUI

/// Makes training coverage visible before a costly fit, with reasons for every rejected night.
struct StageTrainingReadinessCard: View {
    @Environment(StageModelStore.self) private var models
    @Environment(SettingsManager.self) private var settings
    let side: Side
    let builder: StageDatasetBuilder
    let disabled: Bool

    private var current: Bool { models.hasCurrentTrainingAudit(side: side) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Ready to learn?", systemImage: "moon.stars").font(.headline)
            Text("Sleep-stage models compare full Pod recordings with Apple Watch stages. They do not control the bed temperature.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { counts }
                VStack(alignment: .leading, spacing: 12) { counts }
            }
            if models.isTraining && models.trainingKind == nil {
                ProgressView(models.trainingStatus ?? "Checking nights…")
            }
            Button(current ? "Check nights again" : "Check my training nights", systemImage: "checklist") {
                Task { await models.checkTrainingData(builder: builder) }
            }
            .buttonStyle(CapsuleButtonStyle(weight: .filled))
            .disabled(disabled || models.isTraining)
            .accessibilityIdentifier("stageTraining.check")
            if current {
                Text(models.trainingShortfall == nil ? "Coverage checks passed. Training will compare the model with simpler estimates on held-out nights." : "More complete paired nights are needed. Partial recordings stay out of training.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if !models.trainingCandidates.isEmpty {
                    DisclosureGroup("Review actual nights · \(models.confirmedTrainingNights.count) selected") {
                        Text("Select only dates when you wore your Watch throughout an actual full night on this side. Leave test sessions and partial nights unselected. Changed signals require a new review.")
                            .font(.footnote).foregroundStyle(Theme.text2).padding(.vertical, 8)
                        ForEach(models.trainingCandidates) { night in
                            Toggle(isOn: Binding(get: { models.isTrainingNightConfirmed(night) },
                                set: { models.confirmTrainingNight(night, side: side, confirmed: $0) })) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(night.enteredBed.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                                        timeZone: SleepCalendar.calendar(timeZone: settings.timeZone).timeZone)))
                                    Text("\(Int(night.leftBed.timeIntervalSince(night.enteredBed) / 60)) min recorded · \(night.rows.count) matched epochs")
                                        .font(.caption).foregroundStyle(Theme.text2)
                                }
                            }.disabled(models.isTraining)
                        }
                    }.accessibilityIdentifier("stageTraining.review")
                }
                if !models.trainingExclusions.isEmpty {
                    DisclosureGroup("Why nights were excluded") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(models.trainingExclusions) { exclusion in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(exclusion.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                                         timeZone: SleepCalendar.calendar(timeZone: settings.timeZone).timeZone))).font(.subheadline).bold()
                                    Text(exclusion.reason).font(.footnote).foregroundStyle(Theme.text2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 10)
                    }.accessibilityIdentifier("stageTraining.exclusions")
                }
            }
            Text("Each candidate needs a 6–12 hour window, at least 90% matching presence, heart-rate, movement and Watch coverage, and no gap over 30 minutes. These checks identify usable recordings; they do not prove sleep quality.")
                .font(.footnote).foregroundStyle(Theme.text2)
        }.cardStyle().accessibilityIdentifier("stageTraining.readiness")
    }

    @ViewBuilder private var counts: some View {
        Label(current ? "\(models.checkedTrainingNights ?? 0) complete nights" : "Coverage not checked", systemImage: "moon")
            .font(.subheadline).padding(12).background(Theme.cool.opacity(0.12), in: .rect(cornerRadius: 14))
        Label("\(StageDataset.minimumNights) nights needed", systemImage: "checkmark.shield")
            .font(.subheadline).padding(12).background(Theme.active, in: .rect(cornerRadius: 14))
    }
}
