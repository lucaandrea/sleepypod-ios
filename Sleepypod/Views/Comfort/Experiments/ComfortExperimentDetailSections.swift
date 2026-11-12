import SwiftUI

struct ComfortExperimentDetailSections: View {
    @Bindable var model: ComfortExperimentWorkspace
    let detail: ComfortExperimentDetail
    @State private var feedbackDate = ""
    @State private var comfort = 5
    @State private var unwanted = 0
    @State private var fullNight = false
    @State private var problem = false
    @AccessibilityFocusState private var controlFocused: Bool
    private var plan: ComfortExperimentPlan { detail.record.plan }
    private var planStopped: Bool { detail.record.status == "stopped" }
    private var permissionEnded: Bool { model.execution?.state == "ended" || model.execution?.state == "revoked" }
    private var ended: Bool { planStopped || permissionEnded }
    private var incompleteStop: Bool { detail.record.status == "stopped" && model.execution?.state == "admitted" }
    private var completedNights: [ComfortExperimentNight] {
        plan.nights.filter { night in
            plan.schedule?.windows.first(where: { $0.date == night.date }).map { $0.windowEnd <= detail.generatedAt } ?? (night.date < ComfortExperimentContract.localDate(detail.generatedAt, zone: plan.context.timezone))
        }
    }
    var body: some View {
        Section {
            Text(incompleteStop ? "Finish stopping this comparison" : planStopped ? "Comparison ended"
                 : permissionEnded ? "Saved comparison · control ended"
                 : model.execution?.state == "admitted" ? "Scheduled comparison" : "Comparison saved")
                .font(.title2.bold()).accessibilityIdentifier("experiments.status")
            HStack(spacing: 16) {
                target(plan.context.baselineF, title: "Usual setting")
                target(plan.variantF, title: "Comparison")
            }.accessibilityElement(children: .combine)
            if !detail.contextCurrent { Text(detail.contextReason).font(.footnote).foregroundStyle(Theme.amber) }
            if model.canStop {
                Button(incompleteStop ? "Finish stopping control" : permissionEnded ? "Close saved comparison" : "Stop this comparison", role: .destructive) { Task { await model.stop() } }
                    .foregroundStyle(Theme.red).tint(Theme.red)
                    .frame(minHeight: 44).disabled(model.busy).accessibilityIdentifier("experiments.stop")
                Text(permissionEnded && !planStopped
                     ? "Control permission has ended. Close the saved plan before starting another comparison; this does not send a temperature command."
                     : "Stop closes this experiment and ends its control permission. Check the bed controls for the current target.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
        }
        controlSection
        ComfortExperimentScheduleSection(plan: plan)
        Section("Your comparison so far") {
            Text(detail.comparison.reason).accessibilityIdentifier("experiments.comparison")
            LabeledContent("Usual setting", value: "\(detail.comparison.arms.baseline.usable) usable nights")
            LabeledContent("Comparison setting", value: "\(detail.comparison.arms.variant.usable) usable nights")
            if let difference = detail.comparison.meanPairedComfortDifference {
                Text("Comfort rating difference: \(difference.formatted(.number.precision(.fractionLength(1)))) out of 10.")
            }
            Text("This compares your reported comfort. It does not establish sleep improvement or a medical result.")
                .font(.footnote).foregroundStyle(Theme.text2)
            DisclosureGroup("Night-by-night evidence") {
                ForEach(detail.comparison.nights) { night in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(night.date) · \(night.targetF)°F").font(.headline)
                        Text(night.usable ? "Usable for comparison" : night.role == "settling" ? "Settling night" : "Not usable yet").font(.subheadline)
                        if !night.exclusions.isEmpty {
                            Text(night.exclusions.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }.joined(separator: ", "))
                                .font(.footnote).foregroundStyle(Theme.text2)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        if !completedNights.isEmpty { feedbackSection }
    }
    private func target(_ temperature: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(temperature)°F").font(.title2.monospacedDigit().weight(.semibold))
            Text(title).font(.subheadline).foregroundStyle(Theme.text2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var controlSection: some View {
        Section("Overnight control") {
            if let execution = model.execution {
                if let review = execution.review {
                    Text("Allow these scheduled adjustments?").font(.headline).accessibilityFocused($controlFocused)
                        .accessibilityIdentifier("experiments.controlReview")
                    Text("Affects \(review.sides.map { $0.rawValue.capitalized }.joined(separator: " and ")). Each scheduled night uses its assigned \(plan.context.baselineF)°F or \(plan.variantF)°F setting. Wake warming and vibration keep their separate schedule.")
                    Text("Ordinary personal adaptation pauses during this comparison. Safety and manual changes can still withhold adjustments.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                    Button("Allow scheduled comparison") { Task { await model.confirmControl() } }
                        .frame(minHeight: 44).disabled(!model.canConfirmControl).accessibilityIdentifier("experiments.allow")
                    Button("Keep plan only") { model.discardReview() }.frame(minHeight: 44).disabled(model.busy)
                    Text("Review expires in \(model.secondsRemaining) seconds.").font(.footnote).foregroundStyle(Theme.text2)
                } else {
                    Text(incompleteStop ? "Control cancellation needs checking" : execution.state == "admitted" ? "Authorized for the scheduled nights"
                         : execution.state == "not_admitted" ? "Plan saved · control is not authorized" : "Control authorization ended")
                        .accessibilityIdentifier("experiments.controlStatus")
                    if !execution.controllerRunning { Text("The comparison controller is unavailable. Refresh its status before relying on a scheduled adjustment.").foregroundStyle(Theme.amber) }
                    if !ended && detail.contextCurrent && execution.state != "admitted" {
                        Button("Review overnight control") { Task { await model.reviewControl() } }.frame(minHeight: 44)
                            .disabled(!model.canChange).accessibilityIdentifier("experiments.reviewControl")
                    }
                }
                ForEach(execution.applications.filter(\.uncertain)) { application in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(application.side.rawValue.capitalized) target needs checking").font(.headline)
                        Text("The earlier command has no confirmed outcome. Read the current firmware target and end this permission before deciding what to do next.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                        Button("Check \(application.side.rawValue.capitalized) target and end control") { Task { await model.recover(application.id) } }
                            .frame(minHeight: 44).disabled(!model.canChange).accessibilityIdentifier("experiments.recover.\(application.side.rawValue)")
                    }
                }
                if !execution.applications.isEmpty {
                    DisclosureGroup("Latest command receipts") {
                        ForEach(execution.applications) { application in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(application.side.rawValue.capitalized) · requested \(application.requestedTargetF)°F").font(.headline)
                                Text(application.acknowledgment == "accepted_not_physically_verified" ? "Acknowledged by the controller; physical temperature is not verified." : "Earlier command outcome is unconfirmed.")
                                    .font(.footnote).foregroundStyle(Theme.text2)
                                if let resolution = application.resolution { Text("Later firmware readback: \(resolution.targetF.formatted())°F.").font(.footnote) }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            } else { Text("Overnight comparison control is unavailable on this controller. Your saved plan remains available.").foregroundStyle(Theme.text2) }
        }
        .onChange(of: model.execution?.review?.id) { _, value in if value != nil { controlFocused = true } }
    }
    private var feedbackSection: some View {
        Section("Morning comfort") {
            Picker("Night", selection: $feedbackDate) {
                Text("Choose a completed night").tag("")
                ForEach(completedNights) { Text($0.date).tag($0.date) }
            }.accessibilityIdentifier("experiments.feedbackDate")
            Stepper("Comfort: \(comfort) out of 10", value: $comfort, in: 0...10).accessibilityIdentifier("experiments.comfort")
            Text("0 means very uncomfortable; 10 means very comfortable.").font(.footnote).foregroundStyle(Theme.text2)
            Stepper("Unwanted adjustments: \(unwanted)", value: $unwanted, in: 0...100_000)
            Toggle("I used the bed for the full night", isOn: $fullNight)
            Toggle("There was a problem", isOn: $problem)
            Button("Save morning feedback") {
                Task { await model.saveFeedback(.init(nightDate: feedbackDate, confirmedFullNight: fullNight,
                    comfort: comfort, unwantedAdjustments: unwanted, problem: problem)) }
            }.frame(minHeight: 44).disabled(!model.canChange || !completedNights.contains { $0.date == feedbackDate })
                .accessibilityIdentifier("experiments.feedbackSave")
            if let saved = detail.record.feedback.first(where: { $0.nightDate == feedbackDate }) {
                Text("Saved: comfort \(saved.comfort)/10, \(saved.unwantedAdjustments) unwanted adjustments\(saved.problem ? ", problem reported" : "").")
                    .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("experiments.savedFeedback")
            }
        }.disabled(model.busy)
            .onChange(of: feedbackDate) { _, date in
                let saved = detail.record.feedback.first { $0.nightDate == date }
                comfort = saved?.comfort ?? 5; unwanted = saved?.unwantedAdjustments ?? 0
                fullNight = saved?.confirmedFullNight ?? false; problem = saved?.problem ?? false
            }
    }
}
