import SwiftUI

struct ComfortOwnerReviewSheet: View {
    let model: ComfortOwnerWorkspace
    let review: ComfortOwnerReview
    let timezone: String?
    @State private var confirmed = false
    @State private var note = ""
    private var validNote: Bool { note.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= 2000 }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(review.title).font(.title2.bold())
                if model.demo { Text("Synthetic example. Demo cannot confirm physical checks, activate comfort or resolve a real command.").font(.footnote).foregroundStyle(Theme.amber) }
                if let kind = review.kind { Text(kind.instructions).font(.footnote).foregroundStyle(Theme.text2) }
                GroupedCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Captured \(PersonalComfortDates.clock(review.at, timezone: timezone))").font(.footnote)
                        ComfortOwnerIdentityView(identity: review.snapshot.identity)
                        if let evidence = review.snapshot.evidence { evidenceRows(evidence) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                if review.purpose == .activation { activationDetails }
                if review.purpose == .resolution { recoveryDetails }
                GroupedCard {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Observation or note (optional)", text: $note, axis: .vertical).lineLimit(3...8)
                            .accessibilityIdentifier("comfort.owner.note")
                        if !validNote { Text("Use 2,000 characters or fewer.").font(.footnote).foregroundStyle(Theme.amber) }
                        Toggle(review.confirmation, isOn: $confirmed).disabled(model.demo || model.secondsRemaining == 0)
                            .accessibilityIdentifier("comfort.owner.consent")
                        Text(model.secondsRemaining > 0 ? "Review expires in \(model.secondsRemaining) seconds." : "Review expired. Inspect fresh evidence before confirming.")
                            .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("comfort.owner.expiry")
                        Button(review.purpose == .qualification ? "Confirm attended check" : review.title) {
                            Task { _ = await model.confirm(confirmed: confirmed, note: note) }
                        }.buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                            .disabled(!confirmed || !validNote || !model.canConfirm).accessibilityIdentifier("comfort.owner.confirm")
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("comfort.owner.review.scroll")
            .background(Theme.background).navigationTitle("Owner review").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancelReview() }.disabled(model.busy) } }
            .interactiveDismissDisabled(model.busy)
    }
    private func evidenceRows(_ evidence: ComfortOwnerEvidence) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ComfortValueRow("Firmware report", value: evidence.powered ? "On" : evidence.offConfirmed ? "Off" : "Power state unavailable")
            ComfortValueRow("Requested target", value: PersonalComfortScreen.temperature(evidence.targetF))
            ComfortValueRow("Report time", value: PersonalComfortDates.clock(evidence.observedAt, timezone: timezone))
            ComfortValueRow("Calibrated presence", value: evidence.presence.capitalized)
            if let at = evidence.presenceAt { ComfortValueRow("Presence time", value: PersonalComfortDates.clock(at, timezone: timezone)) }
            ComfortValueRow("Temperature acknowledgment", value: evidence.applicationAt.map { PersonalComfortDates.clock($0, timezone: timezone) } ?? "Not part of this check")
            ComfortValueRow("Wake acknowledgment", value: evidence.alarmAt.map { PersonalComfortDates.clock($0, timezone: timezone) } ?? "Not part of this check")
            Text("A firmware acknowledgment does not establish a physical result.").font(.footnote).foregroundStyle(Theme.text2)
        }.font(.footnote)
    }
    private var activationDetails: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bounded thermal adjustments").font(.headline)
                let policy = review.snapshot.identity.policy
                if policy.roomAware == true { Text("Bedroom-aware comfort is included. This review is tied to the selected room sensors and their configuration.").font(.footnote) }
                Text("\(policy.minimumF)–\(policy.maximumF)°F · at most 1°F per 30 minutes · six-hour manual pause. The controller never powers your side on. Missing or unsafe inputs withdraw adjustments.").font(.footnote)
                ComfortOwnerNightsView(nights: review.snapshot.nights)
                Text("This evidence qualifies bounded operation; it does not demonstrate improved sleep or clinical accuracy. A build, routine, calibration, policy or qualification change requires a new review.").font(.footnote).foregroundStyle(Theme.text2)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var recoveryDetails: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Preserve the uncertain outcome").font(.headline)
                if let application = review.snapshot.application {
                    ComfortValueRow("Requested target", value: "\(application.targetF.formatted())°F")
                    Text("Request \(application.requestId)").font(.caption.monospaced()).textSelection(.enabled)
                }
                Text("The original command and this review stay in the audit record. This does not mark the command successful or replay it. Preview resumes with a six-hour pause.").font(.footnote).foregroundStyle(Theme.text2)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
