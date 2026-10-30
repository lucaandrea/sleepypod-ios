import SwiftUI

struct PersonalRoutineReviewScreen: View {
    @Bindable var model: PersonalRoutineWorkspace
    let unit: String
    var body: some View {
        Form {
            if !model.attempts.isEmpty {
                Section("Publication receipts") {
                    ForEach(model.attempts.reversed()) { attempt in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(attempt.receipt == nil ? "Publication outcome unknown" : "Operating week saved").font(.headline)
                                .accessibilityIdentifier("publication.result")
                            Text(attempt.receipt?.message ?? "The request is retained securely. Check its receipt; it will never be resent.")
                                .font(.footnote).foregroundStyle(attempt.unresolved ? Theme.amber : Theme.text2)
                            Text("Request \(attempt.id.uuidString.lowercased())").font(.caption.monospaced()).textSelection(.enabled)
                            Text("\(attempt.review.timeZone) · Thermal: \(zones(attempt.review.temperatureZones)) · Scheduled vibration: \(attempt.review.sourceSide.displayName)")
                                .font(.caption).foregroundStyle(Theme.text2)
                            DisclosureGroup(attempt.receipt == nil ? "Reviewed week" : "Saved week") {
                                ForEach(DayOfWeek.weekdays) { day in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("\(day.displayName) night").font(.headline)
                                        PersonalRoutineDetails(day: day, draft: attempt.review.draftWeek.first { $0.dayOfWeek == day }?.draft, unit: unit)
                                    }.padding(.vertical, 4)
                                }
                            }
                            Button("Check publication receipt") { Task { await model.reconcile(attempt.id) } }
                                .disabled(model.checking.contains(attempt.id)).accessibilityIdentifier("publication.receipt")
                        }.padding(.vertical, 4)
                    }
                }
            }
            if model.hasUnresolved {
                Section {
                    Text("Resolve earlier control or publication receipts before publishing another week. A missing receipt or unconfirmed scheduler refresh must not be repaired by publishing again.")
                        .font(.footnote).foregroundStyle(Theme.amber).accessibilityIdentifier("publication.unresolved")
                }
            }
            if model.enabled {
                Section {
                    Button("Refresh week comparison") { Task { await model.refresh() } }
                        .disabled(model.refreshing || model.publishing).accessibilityIdentifier("publication.refresh")
                    Text("Draft saves remain private plans. Publication replaces the operating week and can affect the current temperature target.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }
            } else {
                Section { Text("Publication is not enabled for this personal account. Saved receipt lookup remains available.").font(.footnote) }
            }
            if model.refreshing { Section { ProgressView("Reading current week…") } }
            if model.publishing { Section { ProgressView("Saving operating week…") } }
            if let error = model.error { Section { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("publication.error") } }
            if let review = model.review {
                Section("Review all seven nights") {
                    Text(review.explanation).font(.footnote).accessibilityIdentifier("publication.reason")
                    Text("Pod time zone · \(review.timeZone)").font(.subheadline)
                    Text("Temperature · \(zones(review.temperatureZones))").font(.subheadline)
                    Text("Scheduled vibration · \(review.sourceSide.displayName) only").font(.subheadline)
                        .accessibilityIdentifier("publication.routing")
                    Text("Nights are named for bedtime. An alarm after midnight wakes you the following morning.").font(.footnote).foregroundStyle(Theme.text2)
                }
                ForEach(DayOfWeek.weekdays) { day in
                    Section("\(day.displayName) night · \(changeLabel(review, day))") {
                        DisclosureGroup {
                            comparison(review, day)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Before · \(summary(review.liveWeek.first { $0.dayOfWeek == day }?.draft))")
                                Text("After · \(summary(review.draftWeek.first { $0.dayOfWeek == day }?.draft))")
                            }.font(.subheadline)
                        }.accessibilityIdentifier("publication.night.\(day.rawValue)")
                    }
                }
                Section("Confirm publication") {
                    Toggle("I reviewed the whole week, including removed nights", isOn: $model.confirmReplaceLiveWeek)
                        .accessibilityIdentifier("publication.confirmWeek")
                    Toggle("I understand this can change the current target", isOn: $model.acknowledgeCurrentTargetEffect)
                        .accessibilityIdentifier("publication.confirmEffect")
                    Text("This saves the operating schedule. A saved receipt or scheduler refresh does not verify physical heating or vibration.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                    Button("Publish reviewed week") { Task { await model.publish() } }
                        .disabled(!model.canPublish).accessibilityIdentifier("publication.publish")
                }.disabled(!review.canPublish || model.publishing || model.hasUnresolved)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Operating week").navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
    }
    private func zones(_ values: [Side]) -> String { values.map(\.displayName).joined(separator: " + ") }
    private func summary(_ draft: BedtimeRoutineDraft?) -> String {
        guard let draft else { return "No routine" }
        let target = unit == "C" ? String(format: "%.1f °C", Double(draft.power.onTemperature - 32) * 5 / 9) : "\(draft.power.onTemperature) °F"
        return "\(draft.power.onTime)–\(draft.power.offTime) · \(target) · \(draft.power.enabled ? "Enabled" : "Paused") · \(draft.temperatures.count) phases"
    }
    private func changeLabel(_ review: PersonalRoutineReview, _ day: DayOfWeek) -> String {
        switch review.changes.first(where: { $0.dayOfWeek == day })?.operation {
        case "remove": "Remove"
        case "create": "Add"
        case "replace": "Replace"
        default: "Unchanged"
        }
    }
    private func comparison(_ review: PersonalRoutineReview, _ day: DayOfWeek) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before · Current week").font(.headline)
            PersonalRoutineDetails(day: day, draft: review.liveWeek.first { $0.dayOfWeek == day }?.draft, unit: unit)
            Divider()
            Text("After · Saved draft").font(.headline)
            PersonalRoutineDetails(day: day, draft: review.draftWeek.first { $0.dayOfWeek == day }?.draft, unit: unit)
        }.padding(.vertical, 6)
    }
}

/// Full routine contents are shown without reconstructing defaults or hiding disabled fields.
struct PersonalRoutineDetails: View {
    let day: DayOfWeek
    let draft: BedtimeRoutineDraft?
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draft {
                Text("Power · \(draft.power.enabled ? "Enabled" : "Paused")")
                Text("Bedtime · \(day.displayName) \(draft.power.onTime) · \(temperature(draft.power.onTemperature))")
                Text("End · \(event(draft.power.offTime, start: draft.power.onTime)) · \(draft.power.endAction.label)")
                if draft.temperatures.isEmpty { Text("No temperature phases") }
                ForEach(Array(draft.temperatures.enumerated()), id: \.offset) { _, phase in
                    Text("Phase · \(event(phase.time, start: draft.power.onTime)) · \(temperature(phase.temperature)) · \(phase.enabled ? "Enabled" : "Paused")")
                }
                if let alarm = draft.alarm {
                    Text("Alarm · \(alarm.enabled ? "Enabled" : "Paused") · \(event(alarm.time, start: draft.power.onTime))")
                    Text("Wake temperature · \(temperature(alarm.alarmTemperature))")
                    Text("Vibration · \(alarm.vibrationPattern.rawValue.capitalized) · \(alarm.vibrationIntensity)% · \(alarm.duration) sec")
                    Text(alarm.wakeWindow == 0 ? "Wake window · Exact time" : "Wake window · \(alarm.wakeWindow) min")
                    Text("Snooze · \(PersonalRoutineWeek.duration(alarm.snoozeDuration ?? 300)) · \(alarm.snoozeTaper ?? 0)% reduction")
                } else { Text("No wake alarm") }
                Text(draft.notes.isEmpty ? "No private notes" : "Notes · \(draft.notes)").textSelection(.enabled)
                if !draft.power.enabled { Text("The paused routine does not run its phases or alarm.").foregroundStyle(Theme.amber) }
            } else { Text("No routine for this bedtime night.") }
        }.font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
    }
    private func temperature(_ value: Int) -> String {
        unit == "C" ? String(format: "%.1f °C", Double(value - 32) * 5 / 9) : "\(value) °F"
    }
    private func event(_ time: String, start: String) -> String {
        "\(BedtimeRoutineTime.eventDay(day, time: time, start: start).displayName) \(time)"
    }
}
