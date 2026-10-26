import SwiftUI

struct BiometricObservationScheduleScreen: View {
    let model: BiometricObservationsWorkspace
    @State private var templateId = ""
    @State private var subject = ""
    @State private var candidate = ""
    @State private var start = ReferenceLabels.utc((Date.now.timeIntervalSince1970 * 1000 + 300000).rounded())
    @State private var end = ReferenceLabels.utc((Date.now.timeIntervalSince1970 * 1000 + 600000).rounded())
    @State private var profiles: BiometricProfilePage?
    @State private var profileCursor: BiometricProfilePage.Cursor?
    @State private var profileError: String?
    @State private var loadingProfiles = false
    @State private var inputError: String?
    var body: some View {
        BiometricReportPage(title: "Schedule an observation") {
            ReferenceSideValue(side: model.side)
            Text("Preparing a plan does not schedule it. The controller checks installed qualification and health again when scheduling and when execution starts.").font(.footnote).foregroundStyle(Theme.text2)
            BiometricObservationPendingCard(model: model)
            if let saved = model.savedRun {
                Text("Observation request saved").font(.headline).accessibilityIdentifier("observations.saved")
                NavigationLink { BiometricObservationDetailScreen(model: model, run: saved) } label: { Label("Inspect saved observation", systemImage: "list.bullet.rectangle") }.accessibilityIdentifier("observations.inspectSaved")
                Button("New observation plan") { model.invalidatePlan() }.disabled(!model.canEdit)
            } else {
                if !model.hasPending {
                    form
                }
                if let prepared = model.prepared {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Review prepared plan").font(.headline).accessibilityIdentifier("observations.prepared")
                        Text("Prepared, not admitted").foregroundStyle(Theme.text2)
                        BiometricProfileValue("Sleeper", value: prepared.plan["subjectId"]?.string ?? "Unavailable")
                        if let start = prepared.plan["startMs"]?.number { BiometricProfileValue("Start · UTC", value: ReferenceLabels.utc(start)) }
                        if let end = prepared.plan["endMs"]?.number { BiometricProfileValue("End · UTC", value: ReferenceLabels.utc(end)) }
                        ForEach(Side.allCases) { side in
                            BiometricProfileValue("\(side.rawValue.capitalized) active generation", value: ReportDisplay.number(prepared.plan["expectedBindings"]?[side.rawValue]?["generation"]?.number))
                        }
                        BiometricProfileIdentity(title: "Candidate hash", value: prepared.plan["candidateConfigHash"]?.string ?? "Unavailable")
                        BiometricProfileIdentity(title: "Plan hash", value: prepared.planHash)
                        if !model.hasPending {
                            Button("Schedule reviewed observation") { Task { await model.schedule() } }.buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                                .disabled(!model.canEdit).accessibilityIdentifier("observations.submit")
                        }
                    }.cardStyle()
                }
            }
            if model.busy { ProgressView("Working…") }
        }.task { await model.loadTemplates(); if !model.templates.isEmpty { await loadProfiles() } }
            .onChange(of: [templateId, subject, candidate, start, end]) { model.invalidatePlan(); inputError = nil }
    }
    @ViewBuilder private var form: some View {
        if let error = model.templatesError { BiometricProfileError(error: error) }
        if !model.templatesLoaded && model.templatesError == nil { ProgressView("Loading installed templates…") }
        Button("Reload templates", systemImage: "arrow.clockwise") { Task { await model.loadTemplates(); await loadProfiles() } }.disabled(model.busy)
        if model.templatesLoaded && model.templates.isEmpty {
            Text("No prospective observation templates are configured on this controller.").foregroundStyle(Theme.text2).accessibilityIdentifier("observations.noTemplates")
        } else if !model.templates.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                BiometricReportMenu(title: "Observation template", selection: $templateId, options: [""] + model.templates.map(\.id)) { id in
                    model.templates.first { $0.id == id }?.label ?? "Choose a template"
                }.accessibilityIdentifier("observations.template")
                if let template = model.templates.first(where: { $0.id == templateId }) {
                    Text("Maximum window: \(ReportDisplay.number(template.maximumWindowMs / 60000)) minutes").font(.footnote).foregroundStyle(Theme.text2)
                }
                TextField("Sleeper identity", text: $subject).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("observations.subject")
                Text("Use the same sleeper identity as the reference records you intend to compare.").font(.footnote).foregroundStyle(Theme.text2)
            }.cardStyle().disabled(!model.canEdit)
            VStack(alignment: .leading, spacing: 12) {
                Text("Candidate profile").font(.headline)
                candidateButton(id: "default", title: "System defaults")
                if let error = profileError { BiometricProfileError(error: error) }
                if loadingProfiles { ProgressView("Loading profiles…") }
                ForEach(profiles?.items ?? []) { profile in
                    candidateButton(id: profile.id, title: "Revision \(profile.revision)")
                    Text(profile.id).font(.caption.monospaced()).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                if profileCursor != nil { Button("Newest profiles") { Task { await loadProfiles() } }.disabled(loadingProfiles) }
                if let next = profiles?.nextCursor { Button("Older profiles") { Task { await loadProfiles(next) } }.disabled(loadingProfiles) }
            }.cardStyle().disabled(!model.canEdit)
            VStack(alignment: .leading, spacing: 12) {
                Text("Observation window · UTC").font(.headline)
                TextField("Start · YYYY-MM-DDTHH:mm:ss.SSSZ", text: $start).font(.subheadline.monospaced()).accessibilityIdentifier("observations.start")
                TextField("End · YYYY-MM-DDTHH:mm:ss.SSSZ", text: $end).font(.subheadline.monospaced()).accessibilityIdentifier("observations.end")
                Text("Use UTC times ending in Z. Seconds and up to three decimal places are supported.").font(.footnote).foregroundStyle(Theme.text2)
            }.textInputAutocapitalization(.never).autocorrectionDisabled().cardStyle().disabled(!model.canEdit)
            if let inputError { BiometricProfileError(error: inputError) }
            Button("Prepare observation plan") {
                do {
                    let input = try request(); inputError = nil
                    Task { await model.prepare(input) }
                } catch { inputError = error.localizedDescription }
            }.disabled(!model.canEdit || templateId.isEmpty || candidate.isEmpty || subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("observations.prepare")
        }
    }
    private func candidateButton(id: String, title: String) -> some View {
        Button { candidate = id } label: {
            HStack(alignment: .top) { Image(systemName: candidate == id ? "checkmark.circle.fill" : "circle"); Text(title).fixedSize(horizontal: false, vertical: true); Spacer() }
        }.accessibilityIdentifier("observations.candidate.\(id)").accessibilityAddTraits(candidate == id ? [.isSelected] : [])
    }
    private func request() throws -> BiometricObservationPreparation {
        guard !candidate.isEmpty else { throw BiometricBacktestInput.error("Choose a candidate profile.") }
        return .init(templateId: templateId, side: model.side, subjectId: subject, candidateRevisionId: candidate == "default" ? nil : candidate,
                     startMs: try BiometricObservationUTC.parse(start), endMs: try BiometricObservationUTC.parse(end))
    }
    private func loadProfiles(_ cursor: BiometricProfilePage.Cursor? = nil) async {
        guard !loadingProfiles else { return }; loadingProfiles = true; defer { loadingProfiles = false }
        do {
            let value = try await model.client.profilesClient.profiles(side: model.side, cursor: cursor)
            guard value.items.allSatisfy({ $0.side == model.side }) else { throw BiometricBacktestInput.error("The candidate library belongs to another side.") }
            guard !Task.isCancelled else { return }; profiles = value; profileCursor = cursor; profileError = nil
        } catch { if !Task.isCancelled { profileError = error.localizedDescription } }
    }
}
enum BiometricObservationUTC {
    static func parse(_ input: String) throws -> Double {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$"#, options: .regularExpression) != nil else { throw invalid }
        let parts = text.dropLast().split(separator: ".")
        let normalized = String(parts[0]) + "." + (parts.count == 2 ? String(parts[1]).padding(toLength: 3, withPad: "0", startingAt: 0) : "000") + "Z"
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: normalized), formatter.string(from: date) == normalized else { throw invalid }
        return (date.timeIntervalSince1970 * 1000).rounded()
    }
    private static var invalid: ReferenceTextError { .init(message: "Enter a valid UTC date such as 2026-10-26T23:00:00.000Z.") }
}
