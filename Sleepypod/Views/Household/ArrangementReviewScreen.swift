import SwiftUI

struct ArrangementReviewScreen: View {
    @Bindable var model: ArrangementReviewWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmingCancellation = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                Section("When you are both ready") {
                    Text("Review your future sides together.").font(.headline)
                    Text("This saves a proposal and each person’s approval. Switching to two sleepers is not available in this release.")
                        .font(.footnote).accessibilityIdentifier("arrangement.boundary")
                    Button("Check current side review") { Task { await model.refresh() } }
                        .disabled(model.busy).accessibilityIdentifier("arrangement.refresh")
                    if model.busy { ProgressView("Checking side review…") }
                    if !model.loaded {
                        Text("Check the current review before making a change. A missing reply is never retried automatically.")
                            .font(.footnote).foregroundStyle(Theme.amber)
                    }
                    if let error = model.error { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("arrangement.error") }
                    if let notice = model.notice { Text(notice).font(.footnote).accessibilityIdentifier("arrangement.notice") }
                }
                if !model.enabled {
                    Section { Text("Side review is not enabled for this personal account. No side changes are available.").accessibilityIdentifier("arrangement.disabled") }
                }
                if let review = model.review { reviewSections(review) }
                if model.mayPrepare { proposal }
                if model.loaded && model.review == nil && model.connection.session.role == "member" {
                    Section { Text("Save your preferences and private weekly draft. The current owner can then prepare a side review for you both.").accessibilityIdentifier("arrangement.waiting") }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Shared side review").navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } } else { model.suspend() }
        }
        .confirmationDialog("Cancel this side review for both people?", isPresented: $confirmingCancellation, titleVisibility: .visible) {
            Button("Cancel side review", role: .destructive) { Task { await model.cancel() } }
        } message: { Text("Any saved approvals belong to this review. Your current bed arrangement and routines stay unchanged.") }
    }
    @ViewBuilder private func reviewSections(_ review: ArrangementReview) -> some View {
        Section("Proposed sides only") {
            Text(model.currentState?.message ?? review.state.message).font(.headline).accessibilityIdentifier("arrangement.status")
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 16) { sides(review) }
            } else {
                HStack(alignment: .top, spacing: 16) { sides(review) }
            }
            Text("Your original assignment · \(review.person.assignmentAtReview == "solo" ? "Only sleeper" : "No side assigned")")
                .font(.footnote).foregroundStyle(Theme.text2)
            Text("Review valid until \(expiry(review)). Changing either person’s settings or revoking an approving device requires fresh approvals.")
                .font(.footnote).foregroundStyle(Theme.text2)
        }
        Section("Your settings in this review") {
            LabeledContent("Preferred temperature", value: temperature(review.person.preferences))
            LabeledContent("Display unit", value: review.person.preferences.displayUnit == "C" ? "Celsius" : "Fahrenheit")
            LabeledContent("Comfort", value: review.person.preferences.comfort.replacingOccurrences(of: "_", with: " ").capitalized)
            LabeledContent("Share wake time", value: review.person.preferences.shareWakeTime ? "On" : "Off")
            Text("Your partner’s routine and health history stay private. Cloud analysis is off.").font(.footnote).foregroundStyle(Theme.text2)
            Text(review.person.routineSource == "preserved_operating_week"
                 ? "Your current operating week is preserved here, including disabled nights, notes and wake alarms. Unpublished drafts do not replace it."
                 : "Your saved private draft is included here for your proposed side.")
                .font(.footnote).accessibilityIdentifier("arrangement.source")
        }
        Section("Your full week · \(review.timeZone)") {
            Text("Nights are named for bedtime. Wake warming begins 30 minutes before an enabled alarm; a paused night does not run its alarm.")
                .font(.footnote).foregroundStyle(Theme.text2)
            ForEach(DayOfWeek.weekdays) { day in
                DisclosureGroup("\(day.displayName) night") {
                    PersonalRoutineDetails(day: day, draft: review.person.week.first { $0.dayOfWeek == day }?.draft, unit: review.person.preferences.displayUnit)
                }.accessibilityIdentifier("arrangement.night.\(day.rawValue)")
            }
        }
        if !review.person.approved {
            Section("Your independent approval") {
                Toggle("I reviewed my proposed side", isOn: $model.confirmMySide).accessibilityIdentifier("arrangement.confirmSide")
                Toggle("I reviewed my temperatures, nights and wake alarms", isOn: $model.confirmMyRoutine).accessibilityIdentifier("arrangement.confirmRoutine")
                Toggle("I understand switching the bed needs a separate activation", isOn: $model.acknowledgeSeparateActivation).accessibilityIdentifier("arrangement.confirmActivation")
                Button("Approve my side and routine") { Task { await model.approve() } }
                    .disabled(!model.canApprove).accessibilityIdentifier("arrangement.approve")
            }.disabled(!model.enabled || !model.loaded || model.busy || model.needsReconciliation || !review.canApprove || model.currentState != .awaitingApproval)
        }
        if review.state != .cancelled && review.state != .consumed {
            Section {
                Button("Cancel side review", role: .destructive) { confirmingCancellation = true }
                    .disabled(!model.canCancel).accessibilityIdentifier("arrangement.cancel")
            }
        }
    }
    @ViewBuilder private func sides(_ review: ArrangementReview) -> some View {
        ForEach([Side.left, Side.right], id: \.self) { side in
            let own = side == review.person.proposedSide
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "bed.double").font(.title2).foregroundStyle(Theme.accent).accessibilityHidden(true)
                Text(side.displayName).font(.headline)
                Text(own ? review.person.displayName : review.partner.displayName).font(.subheadline)
                Text(own ? "Your proposed side" : "Partner’s proposed side").font(.caption)
                Text((own ? review.person.approved : review.partner.approved) ? "Approval saved" : "Waiting for approval").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine).accessibilityIdentifier("arrangement.side.\(side.rawValue)")
        }
    }
    private var proposal: some View {
        Section("Prepare a shared review") {
            Text("Both people first save their own preferences. The joining person also saves their private weekly draft. Existing calendar schedules must already be reviewed.").font(.footnote)
            if dynamicTypeSize.isAccessibilitySize { sidePicker.pickerStyle(.inline) }
            else { sidePicker.pickerStyle(.segmented) }
            Toggle("Keep my current operating week, including wake alarms, for my proposed side", isOn: $model.preserveOperatingWeek)
                .accessibilityIdentifier("arrangement.preserveWeek")
            Button("Prepare shared side review") { Task { await model.propose() } }
                .disabled(!model.canPropose).accessibilityIdentifier("arrangement.propose")
        }
    }
    private var sidePicker: some View {
        Picker("My future side", selection: $model.ownerSide) {
            Text("Left").tag(Side.left)
            Text("Right").tag(Side.right)
        }.accessibilityIdentifier("arrangement.ownerSide")
    }
    private func temperature(_ value: HouseholdPreferences) -> String {
        value.displayUnit == "C" ? String(format: "%.1f °C", Double(value.preferredTemperatureF - 32) * 5 / 9) : "\(value.preferredTemperatureF) °F"
    }
    private func expiry(_ review: ArrangementReview) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: TimeZone(identifier: review.timeZone) ?? .gmt)
        return Date(timeIntervalSince1970: Double(review.expiresAt) / 1_000).formatted(style) + " · " + review.timeZone
    }
}
