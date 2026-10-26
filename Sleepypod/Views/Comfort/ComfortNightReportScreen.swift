import SwiftUI

private struct ComfortReviewSession: Identifiable {
    let id = UUID()
    let report: ComfortNightDetail
}
struct ComfortNightReportScreen: View {
    @Environment(\.scenePhase) private var phase
    @State private var model: ComfortNightWorkspace
    @State private var reviewSession: ComfortReviewSession?
    init(client: any PersonalComfortClient, side: Side, id: String) { _model = State(initialValue: ComfortNightWorkspace(client: client, side: side, id: id)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if APIBackend.current.isDemo { Eyebrow("SIMULATED EXAMPLE · CANNOT QUALIFY", color: Theme.amber) }
                if model.busy { ProgressView("Reading Preview report…") }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("comfort.review.notice") }
                if let detail = model.detail {
                    summary(detail)
                    evidence(detail)
                    observations(detail)
                    if let review = detail.review {
                        GroupedCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Saved review").font(.headline)
                                Text(review.outcome == "reviewed" ? "Owner confirmed actual night" : "Needs retest")
                                Text(PersonalComfortDates.clock(review.at, timezone: detail.summary.metadata.timezone)).font(.caption).foregroundStyle(Theme.text2)
                                if !review.note.isEmpty { Text(review.note).font(.footnote) }
                                if !detail.reviewCurrent { Text("The recorded evidence changed. Review this report again.").foregroundStyle(Theme.amber).font(.footnote) }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if detail.summary.state == "closed" {
                        Button("Review this night") { reviewSession = .init(report: detail) }.accessibilityIdentifier("comfort.review.open").disabled(model.busy)
                    }
                }
                Button("Refresh report") { Task { await model.load() } }.disabled(model.busy).accessibilityIdentifier("comfort.report.refresh")
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Preview report").navigationBarTitleDisplayMode(.inline)
            .task(id: phase) { guard phase == .active else { model.invalidate(); reviewSession = nil; return }; await model.load() }
            .onDisappear { model.invalidate() }
            .sheet(item: $reviewSession) { session in NavigationStack { ComfortReviewEditor(model: model, report: session.report) }.tint(Theme.text1) }
    }
    private func summary(_ detail: ComfortNightDetail) -> some View {
        let summary = detail.summary
        return GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(summary.localDate).font(.title3.bold())
                Text(detail.item.label).font(.subheadline)
                Text("\(clock(summary.metadata.start, summary)) → \(clock(summary.metadata.end, summary)) · \(summary.metadata.timezone)").font(.caption).foregroundStyle(Theme.text2)
                ComfortValueRow("Occupied intervals", value: PersonalComfortDates.duration(summary.occupiedObservationMs))
                ComfortValueRow("Proposals / recorded checks", value: "\(summary.eligibleCount) / \(summary.observationCount)")
                ComfortValueRow("Sensor-ready checks", value: "\(summary.sensorReadyCount) / \(summary.observationCount)")
                ComfortValueRow("Fresh device checks", value: "\(summary.deviceFreshCount) / \(summary.observationCount)")
                ComfortValueRow("Manual-pause checks", value: String(summary.manualPauseCount))
                ComfortValueRow("Proposed targets", value: range(summary.proposedRangeF))
                ComfortValueRow("Reported targets", value: range(summary.reportedRangeF))
                Text("Occupied intervals are sampled checks, not measured sleep duration. At least four hours of qualifying intervals are required for owner confirmation.").font(.footnote).foregroundStyle(Theme.text2)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func evidence(_ detail: ComfortNightDetail) -> some View {
        let summary = detail.summary
        return GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Evidence and gaps").font(.headline)
                Text("Runtime sessions: \(summary.runs) · Configurations: \(summary.configurations) · Gaps over 90 seconds: \(summary.gapCount)").font(.footnote)
                Text("First check \(clock(summary.firstAt, summary))\nLast check \(clock(summary.lastAt, summary))").font(.caption).foregroundStyle(Theme.text2)
                ForEach(Array(summary.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.footnote).foregroundStyle(Theme.amber) }
                DisclosureGroup("Recorded reasons and gaps") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(summary.reasons.enumerated()), id: \.offset) { _, reason in Text("\(reason.count) checks: \(reason.message)").font(.footnote) }
                        ForEach(Array(summary.gaps.enumerated()), id: \.offset) { _, gap in Text("\(clock(gap.from, summary)) → \(clock(gap.to, summary))\nNo continuous journal coverage.").font(.caption) }
                        if summary.gapCount > summary.gaps.count { Text("Showing the first \(summary.gaps.count) gaps.").font(.caption) }
                        if !summary.builds.isEmpty { Text("Recorded builds: \(summary.builds.joined(separator: ", "))").font(.caption).textSelection(.enabled) }
                    }.padding(.top, 10)
                }.accessibilityIdentifier("comfort.report.evidence")
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func observations(_ detail: ComfortNightDetail) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recorded observations").font(.headline)
                if detail.observations.isEmpty { Text("No observations on this page.").foregroundStyle(Theme.text2) }
                ForEach(detail.observations) { observation in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(clock(observation.at, detail.summary)).font(.caption).foregroundStyle(Theme.text2)
                        Text(observation.message).font(.footnote)
                        Text("Proposed \(PersonalComfortScreen.temperature(observation.proposedF)) · reported \(PersonalComfortScreen.temperature(observation.reportedF))").font(.caption).foregroundStyle(Theme.text2)
                    }.accessibilityIdentifier("comfort.observation.\(observation.id)")
                    Divider()
                }
                if model.after != nil { Button("First observations") { Task { await model.load() } }.accessibilityIdentifier("comfort.observations.first") }
                if let after = detail.nextAfterId { Button("Next observations") { Task { await model.load(after: after) } }.accessibilityIdentifier("comfort.observations.next") }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(model.busy)
    }
    private func clock(_ value: Double, _ summary: ComfortNightSummary) -> String { PersonalComfortDates.clock(value, timezone: summary.metadata.timezone) }
    private func range(_ value: ComfortNightSummary.Range?) -> String { value.map { "\($0.minimum.formatted())–\($0.maximum.formatted())°F" } ?? "Unavailable" }
}

struct ComfortReviewEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: ComfortNightWorkspace
    let report: ComfortNightDetail
    @State private var draft: ComfortReviewInput
    init(model: ComfortNightWorkspace, report: ComfortNightDetail) { self.model = model; self.report = report; _draft = State(initialValue: ComfortReviewInput(side: model.side, report: report)) }
    private var valid: Bool { (try? draft.validate(report: report)) != nil && (!APIBackend.current.isDemo || (!draft.confirmedActualNight && draft.outcome == "needs_retest")) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(report.summary.localDate).font(.title3.bold())
                GroupedCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Review conclusion").font(.headline)
                        Menu {
                            Button("Needs retest") { draft.outcome = "needs_retest" }
                            if report.summary.reviewable && !APIBackend.current.isDemo { Button("Reviewed actual night") { draft.outcome = "reviewed" } }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(draft.outcome == "reviewed" ? "Reviewed actual night" : "Needs retest").fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down").font(.caption)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("comfort.review.outcome")
                        if APIBackend.current.isDemo { Text("Simulated examples cannot count as actual nights.").font(.footnote).foregroundStyle(Theme.amber) }
                        else {
                            Toggle("I used this side for an actual overnight Preview session and reviewed these observations.", isOn: $draft.confirmedActualNight).accessibilityIdentifier("comfort.review.actualNight")
                        }
                        Text("Review notes").font(.headline)
                        TextField("What did you observe?", text: $draft.note, axis: .vertical).lineLimit(3...10).accessibilityIdentifier("comfort.review.note")
                        Text("\(draft.note.utf16.count) / 2000").font(.caption).foregroundStyle(Theme.text2)
                    }.padding(16)
                }
                Text("A saved review never enables active bed adjustments. Confirmation remains tied to this exact report and its prior review.").font(.footnote).foregroundStyle(Theme.text2)
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Review night").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Save review") { Task { if await model.save(draft) { dismiss() } } }.disabled(!valid || model.busy || model.detail == nil).accessibilityIdentifier("comfort.review.save") }
            }.interactiveDismissDisabled(model.busy)
    }
}
