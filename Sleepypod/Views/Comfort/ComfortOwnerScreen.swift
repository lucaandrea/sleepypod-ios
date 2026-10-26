import SwiftUI

struct ComfortOwnerScreen: View {
    let side: Side
    let timezone: String?
    @Environment(\.scenePhase) private var phase
    @Environment(SettingsManager.self) private var settings
    @State private var model = ComfortOwnerWorkspace()
    @State private var kind = ComfortQualificationKind.presenceEmpty
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var address = ""
    @AppStorage("podIPAddress") private var host = ""
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    private var scope: String { "\(backend)|\(address)|\(host)|\(ownerRevision)|\(side.rawValue)|\(phase)" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(settings.sideName(for: side)).font(.title3.bold())
                if APIBackend.current.isDemo { Eyebrow("DEMO · SYNTHETIC EVIDENCE", color: Theme.amber) }
                Text("Recorded signals and acknowledgments are separate from your physical observations. These checks do not enable automatic base movement, music vibration or house automations.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if model.busy { ProgressView("Reading qualification evidence…") }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("comfort.owner.error") }
                if let notice = model.notice { Text(notice).font(.footnote).accessibilityIdentifier("comfort.owner.notice") }
                if let status = model.status { overview(status); qualifications(status); actions(status) }
                Button("Refresh evidence") { Task { await model.load() } }.disabled(model.busy).accessibilityIdentifier("comfort.owner.refresh")
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("comfort.owner.scroll")
            .background(Theme.background).navigationTitle("Qualification & activation").navigationBarTitleDisplayMode(.inline)
            .task(id: scope) {
                guard phase == .active else { model.invalidate(); return }
                let client: (any ComfortOwnerClient)? = APIBackend.current.isDemo ? ComfortOwnerExampleClient(scenario: DebugRoute.comfortOwnerScenario)
                    : (try? CoreRESTClient.configured()).map { CoreComfortOwnerClient(transport: $0) }
                model.configure(client: client, side: side, demo: APIBackend.current.isDemo); await model.load()
                while !Task.isCancelled { do { try await Task.sleep(for: .seconds(1)) } catch { return }; model.tick() }
            }
            .onDisappear { model.invalidate() }
            .sheet(item: Binding(get: { model.review }, set: { if $0 == nil { model.cancelReview() } })) { review in
                NavigationStack { ComfortOwnerReviewSheet(model: model, review: review, timezone: timezone) }.tint(Theme.text1)
            }
    }
    private func overview(_ status: ComfortOwnerStatus) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(status.active ? "Owner activation current" : "Activation requires review").font(.headline).accessibilityIdentifier("comfort.owner.status")
                ComfortValueRow("Matching nights", value: "\(status.nights.count) / 7")
                if !status.nights.isEmpty { ComfortOwnerNightsView(nights: status.nights) }
                ForEach(Array(status.reasons.enumerated()), id: \.offset) { _, reason in Text(reason).font(.footnote).foregroundStyle(Theme.text2) }
                if let identity = status.identity { ComfortOwnerIdentityView(identity: identity) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func qualifications(_ status: ComfortOwnerStatus) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Attended checks").font(.headline)
                ForEach(ComfortQualificationKind.allCases) { selected in
                    let record = status.qualifications.first { $0.kind == selected }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selected.title).font(.subheadline.weight(.medium))
                        Text(record?.label(identity: status.identity) ?? "Not yet qualified").font(.footnote).foregroundStyle(Theme.text2)
                        if let record {
                            Text(PersonalComfortDates.clock(record.at, timezone: timezone)).font(.caption).foregroundStyle(Theme.text2)
                            if !record.note.isEmpty { Text(record.note).font(.footnote) }
                            if record.outcome == "confirmed" {
                                Button("Needs retest") { Task { await model.retest(record) } }
                                    .disabled(model.busy || model.requiresReload || model.demo).accessibilityIdentifier("comfort.owner.retest.\(selected.rawValue)")
                            }
                        }
                    }
                    if selected != .offlineRoutine { Divider() }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func actions(_ status: ComfortOwnerStatus) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Attended check", selection: $kind) { ForEach(ComfortQualificationKind.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.menu).disabled(model.busy || status.active).accessibilityIdentifier("comfort.owner.kind")
                Text(kind.instructions).font(.footnote).foregroundStyle(Theme.text2)
                Button("Inspect check evidence") { Task { await model.prepare(.qualification, kind: kind) } }
                    .disabled(status.active || status.identity == nil || model.requiresReload || model.error != nil).accessibilityIdentifier("comfort.owner.inspect")
                Button("Review activation") { Task { await model.prepare(.activation) } }
                    .disabled(!status.canActivate || model.requiresReload || model.error != nil).accessibilityIdentifier("comfort.owner.activate")
                if let application = status.application, application.uncertain {
                    Divider()
                    Text("Unconfirmed temperature command").font(.headline)
                    Text("Requested \(application.targetF.formatted())°F at \(PersonalComfortDates.clock(application.reservedAt, timezone: timezone)). Its outcome is unknown; it will not be retried automatically.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                    Button("Inspect recovery evidence") { Task { await model.prepare(.resolution) } }
                        .disabled(model.requiresReload || model.error != nil).accessibilityIdentifier("comfort.owner.recover")
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(model.busy)
    }
}

struct ComfortOwnerIdentityView: View {
    let identity: ComfortOwnerIdentity
    var body: some View {
        DisclosureGroup("Controller identity") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Build \(identity.build)")
                Text("Pod \(identity.hardware)")
                Text("Calibration \(identity.calibration)")
                Text("Routine \(identity.schedule)")
            }.font(.caption.monospaced()).textSelection(.enabled).padding(.top, 8)
        }.font(.footnote).foregroundStyle(Theme.text2)
    }
}

struct ComfortOwnerNightsView: View {
    let nights: [ComfortOwnerNight]
    var body: some View {
        DisclosureGroup("\(nights.count) matching reviewed nights") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(nights) { night in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(night.summary.localDate).font(.subheadline.weight(.medium))
                        Text("\((night.eligibleMs / 3_600_000).formatted(.number.precision(.fractionLength(1)))) hours of eligible observations · owner review #\(night.reviewId)")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
            }.padding(.top, 12)
        }.accessibilityIdentifier("comfort.owner.nights")
    }
}
