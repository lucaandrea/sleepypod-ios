import SwiftUI

/// An inline one-occurrence review shares the wake card's existing layout and tokens.
struct LaterWakeReview: View {
    let model: NextAlarmWorkspace
    let companion: LaterWakeCompanion
    let draft: NextAlarmWorkspace.LaterDraft
    let temperatureUnit: TemperatureFormat
    let now: Date
    @Environment(\.dynamicTypeSize) private var typeSize
    private var busy: Bool { model.busy || companion.busy }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text("Wake later once").font(.title3.weight(.semibold))
            if APIBackend.current.isDemo { Text("Practice only. No devices are changed.").font(.footnote).foregroundStyle(Theme.text2) }
            Text("Current wake: \(draft.base.alarm.map { draft.base.label($0.at) } ?? "Unavailable") · \(draft.base.timeZone)")
                .font(.subheadline).foregroundStyle(Theme.text2)
            if typeSize.isAccessibilitySize { Text("Later wake time"); picker.labelsHidden() } else { picker }
            if typeSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 8) { timeChoices } }
            else { HStack(spacing: 16) { timeChoices } }
            Text("Choose a later time on this wake date. Your weekly schedule stays saved.")
                .font(.footnote).foregroundStyle(Theme.text2)
            Toggle("Include this device’s backup alarm", isOn: Binding(get: { companion.includePhone }, set: { companion.setPhone($0) }))
                .disabled(busy).accessibilityIdentifier("laterWake.phone")
            Text(companion.includePhone
                 ? "Review an app-owned backup at the same new wake time. Other Clock alarms stay unchanged."
                 : "The Pod changes alone. Phone alarms, lights, shades and audio stay unchanged.")
                .font(.footnote).foregroundStyle(Theme.text2)
            if model.laterChanged {
                message("The saved alarm changed. Close this review and start from the new saved alarm.", id: "laterWake.changed")
            } else if !model.isFresh || model.requiresReload {
                message("Refresh the saved alarm below before continuing. Your chosen time is kept.", id: "laterWake.unavailable")
            }
            if model.requiresReload, companion.includePhone {
                Text("The phone backup was not changed because the Pod save was not confirmed. Check both plans after refreshing.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            if let error = companion.error { message(error, id: "laterWake.error") }
            if let review = companion.review, review.packet == model.laterDraft?.packet {
                proposal(review)
            }
            Button(companion.review == nil ? "Preview changes" : "Refresh preview", systemImage: "doc.text.magnifyingglass") {
                Task { await companion.preview(model) }
            }.disabled(busy || !model.canPreviewLater).frame(minHeight: 44).accessibilityIdentifier("laterWake.preview")
            if companion.review != nil {
                Button(companion.includePhone ? "Save Pod and phone backup" : "Save later wake") {
                    Task { await companion.apply(model) }
                }.buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                    .disabled(!companion.canApply(model)).frame(minHeight: 44)
                    .accessibilityIdentifier("laterWake.save")
            }
            Button("Close review") { companion.clearReview(); model.closeLater() }
                .disabled(busy).frame(minHeight: 44).accessibilityIdentifier("laterWake.close")
        }
    }
    private var picker: some View {
        DatePicker("Later wake time", selection: clock, displayedComponents: .hourAndMinute)
            .environment(\.timeZone, TimeZone(identifier: draft.base.timeZone) ?? .gmt)
            .environment(\.calendar, Calendar(identifier: .gregorian)).disabled(busy)
            .accessibilityIdentifier("laterWake.time")
    }
    @ViewBuilder private var timeChoices: some View {
        ForEach([30, 60], id: \.self) { minutes in
            Button(minutes == 30 ? "30 minutes later" : "1 hour later") {
                guard let original = draft.base.alarm.flatMap({ NextAlarmState.instant($0.at) }) else { return }
                changeTime(NextAlarmState.clock(original.addingTimeInterval(Double(minutes * 60)), timeZone: draft.base.timeZone))
            }.disabled(busy).frame(minHeight: 44).accessibilityIdentifier("laterWake.add\(minutes)")
        }
    }
    private func proposal(_ review: LaterWakeCompanion.Review) -> some View {
        let preview = review.packet.preview, proposed = preview.proposed
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Review this wake-up").font(.headline)
            Label("Vibration: \(preview.before.label(proposed.at)) · \(proposed.duration.formatted()) seconds", systemImage: "alarm")
                .accessibilityIdentifier("laterWake.vibration")
            Label("Warm-up: \(preview.before.label(proposed.warmingStartsAt)) toward \(TemperatureConversion.displayTemp(Int(proposed.targetF.rounded()), format: temperatureUnit))", systemImage: "thermometer.medium")
                .accessibilityIdentifier("laterWake.warming")
            if proposed.wakeWindow > 0 {
                Text("Movement may start vibration from \(preview.before.label(proposed.earliestVibrationAt)).").font(.subheadline)
            }
            Text("Warm hold ends \(preview.before.label(proposed.warmingEndsAt)). This one-time change then expires; the saved weekly schedule remains in place.")
                .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("laterWake.restoration")
            if let phone = review.phone {
                Label("Phone backup: \(preview.before.label(proposed.at))", systemImage: "iphone")
                if case .existing(let previous) = phone {
                    Text("Replace the app’s backup at \(preview.before.label(previous.at.ISO8601Format())). The old backup is removed first; a failure can leave no phone backup.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                } else { Text("Add one app-owned system alarm after the Pod confirms its change.").font(.footnote).foregroundStyle(Theme.text2) }
                Text("Lights, shades, audio and other Clock alarms stay unchanged.").font(.footnote).foregroundStyle(Theme.text2)
            }
            if model.laterExpired || NextAlarmState.instant(preview.expiresAt).map({ now >= $0 }) == true {
                message("This preview expired. Refresh the saved alarm, then preview again.", id: "laterWake.expired")
            } else {
                Text("Review expires \(preview.before.label(preview.expiresAt)). Nothing has changed yet.")
                    .font(.footnote).accessibilityIdentifier("laterWake.expiry")
            }
        }
    }
    private func message(_ text: String, id: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Theme.text1)
            .accessibilityIdentifier(id)
    }
    private func changeTime(_ time: String) { companion.clearReview(); model.editLaterTime(time) }
    private var clock: Binding<Date> {
        Binding(get: {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: draft.base.timeZone) ?? .gmt
            let minutes = AlarmDraft.clockMinutes(model.laterDraft?.time ?? draft.time) ?? 420
            return calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: minutes / 60, minute: minutes % 60)) ?? .now
        }, set: { changeTime(NextAlarmState.clock($0, timeZone: draft.base.timeZone)) })
    }
}

struct LaterWakeResultView: View {
    let outcome: LaterWakeCompanion.Outcome
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if APIBackend.current.isDemo { Text("Practice result. No devices were changed.").font(.footnote).foregroundStyle(Theme.text2) }
            Label("Later wake saved on the Pod", systemImage: "checkmark.circle").font(.headline)
            if let alarm = outcome.plan.alarm { Text(outcome.plan.label(alarm.at)).font(.subheadline) }
            Text(outcome.plan.schedulerUpdated == true ? "Controller timers confirmed. Physical alarm delivery is not yet verified."
                 : "Controller timer registration is still pending. Refresh the saved alarm to check it.").font(.footnote).foregroundStyle(Theme.text2)
            switch outcome.phone {
            case .unchanged: Text("Phone alarms and other wake devices were not changed.").font(.footnote).foregroundStyle(Theme.text2)
            case .confirmed: Label("Phone backup scheduled", systemImage: "iphone").font(.subheadline)
            case .unconfirmed: Label("Phone backup not confirmed", systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Theme.text1)
            }
            if let message = outcome.phoneMessage { Text(message).font(.footnote).foregroundStyle(Theme.text2) }
            if outcome.phone == .unconfirmed {
                Text("Your Pod change remains saved. Open Phone backup and wake devices below, then check the phone alarm before replacing it. No request was retried.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
        }.accessibilityIdentifier("laterWake.result")
    }
}
