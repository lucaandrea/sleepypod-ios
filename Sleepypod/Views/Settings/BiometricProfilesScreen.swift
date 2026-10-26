import SwiftUI

struct BiometricProfilesScreen: View {
    @Environment(SettingsManager.self) private var settings
    @State private var side: Side = .left
    @State private var model: BiometricProfilesWorkspace?
    @State private var error: String?
    @State private var demo = DemoBiometricProfilesClient()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Profile side", selection: $side) {
                    ForEach(Side.allCases) { Text(settings.sideName(for: $0)).tag($0) }
                }.pickerStyle(.segmented).disabled(model?.busy == true).accessibilityIdentifier("profiles.side")
                if let model {
                    if APIBackend.current.isDemo { Text("Demo · profile changes stay in memory. No processor or validation evidence is simulated.").font(.footnote).foregroundStyle(Theme.text2) }
                    GroupedCard {
                        NavigationLink { BiometricBacktestsScreen(side: model.side) } label: { SettingsRow("Backtests", icon: "chart.xyaxis.line", tile: true, chevron: true) }.accessibilityIdentifier("profiles.backtests")
                        NavigationLink { BiometricReferencesScreen(side: model.side) } label: { SettingsRow("References", icon: "doc.text.magnifyingglass", tile: true, chevron: true) }.accessibilityIdentifier("profiles.references")
                        NavigationLink { BiometricProfileLibraryScreen(model: model) } label: { SettingsRow("Profiles", icon: "slider.horizontal.3", tile: true, chevron: true) }.accessibilityIdentifier("profiles.library")
                        NavigationLink { BiometricProfileHistoryScreen(model: model) } label: { SettingsRow("History", icon: "clock", tile: true, chevron: true) }.accessibilityIdentifier("profiles.history")
                    }
                    BiometricProfilePendingCard(model: model)
                    BiometricProfileOverviewContent(model: model)
                    BiometricProfileRecoveryCard(model: model)
                } else if let error {
                    BiometricProfileError(error: error)
                    Button("Retry") { Task { await configure() } }
                } else { ProgressView("Loading biometric profiles…") }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Biometric calibration").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("profiles.content")
            .task(id: side) { await configure() }
            .modifier(BiometricProfileObservation(model: model))
    }
    private func configure() async {
        model = nil; error = nil
        do {
            let client: any BiometricProfilesServing = APIBackend.current.isDemo ? demo : CoreBiometricProfilesClient(transport: try .configured())
            let store = APIBackend.current.isDemo ? BiometricProfilePendingStore(directory: nil) : try .persistent()
            let workspace = BiometricProfilesWorkspace(side: side, client: client, pendingStore: store)
            guard !Task.isCancelled else { return }
            model = workspace
            await workspace.refresh()
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct BiometricProfileObservation: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let model: BiometricProfilesWorkspace?
    func body(content: Content) -> some View {
        content.task(id: "\(scenePhase)-\(model?.side.rawValue ?? "none")") {
            guard scenePhase == .active, let model else { return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}

struct BiometricProfileOverviewContent: View {
    let model: BiometricProfilesWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.refreshing && model.overview == nil { ProgressView("Loading processor reports…") }
            if let error = model.overviewError { BiometricProfileError(error: error) }
            Button("Refresh reports", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.refreshing)
            if let overview = model.overview {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let fresh = model.isFresh(at: .now)
                    let elapsed = Date.now.timeIntervalSince(model.observedAt ?? .distantPast) * 1000
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Profile and processor").font(.headline)
                        Text("Saved settings and processor reports are separate.").font(.footnote).foregroundStyle(Theme.text2)
                        BiometricProfileValue("Saved profile", value: overview.desired.isDefault ? "System defaults" : "Personalized profile")
                        if let warning = overview.desired.warning { BiometricProfileError(error: warning) }
                        BiometricProfileValue("Requested change", value: model.activationError == nil ? BiometricProfileLabels.state(model.activation?.observedState ?? "unreported") : "Report unavailable")
                        if let error = model.activationError { BiometricProfileError(error: error) }
                        BiometricProfileValue("Processor health", value: fresh ? BiometricProfileLabels.state(overview.runtimeHealth.state(after: elapsed)) : "Report needs refresh")
                        ForEach(overview.runtimeHealth.components) { component in
                            BiometricProfileValue(BiometricProfileLabels.component(component.component), value: fresh ? BiometricProfileLabels.state(overview.runtimeHealth.state(component, after: elapsed)) : "Last report: \(BiometricProfileLabels.state(component.state))")
                        }
                        DisclosureGroup("Configuration identity") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Generation \(overview.desired.binding.generation)")
                                BiometricProfileIdentity(title: "Saved revision", value: overview.desired.binding.desiredRevisionId ?? "System defaults")
                                BiometricProfileIdentity(title: "Configuration hash", value: overview.desired.hash)
                                BiometricProfileIdentity(title: "Stage source", value: overview.stageView.provenance.source)
                                if let generation = overview.stageView.provenance.generation { Text("Stage generation \(generation)") }
                                BiometricProfileIdentity(title: "Stage hash", value: overview.stageView.provenance.stageHash)
                                if let time = overview.stageView.provenance.effectiveSampleTimeMs { BiometricProfileDate(title: "Stage boundary", milliseconds: time) }
                            }.padding(.top, 8)
                        }
                        if !overview.receipts.isEmpty {
                            DisclosureGroup("Processor receipts") { BiometricProfileReceipts(receipts: overview.receipts) }
                        }
                    }.cardStyle()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("What these metrics mean").font(.headline)
                    Text("The HRV index measures window IBI variability. It is not clinical beat-to-beat RMSSD, and incompatible reference metrics cannot validate it.")
                    Text("Historical sleep stages are recomputed with the current classifier. Original stored vitals remain separate from replay results.")
                    if overview.legacyStageView.migrationPending { Text("Existing personalized stage rules are awaiting profile migration.").foregroundStyle(Theme.amber) }
                    if let warning = overview.stageView.provenance.warning { BiometricProfileError(error: warning) }
                }.font(.footnote).foregroundStyle(Theme.text2).cardStyle()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Measured sensor calibration").font(.headline)
                    Text("Sensor measurements are separate from algorithm personalization.").foregroundStyle(Theme.text2)
                    if overview.sensorCalibration.isEmpty { Text("No sensor calibration has been reported for this side.").foregroundStyle(Theme.text2) }
                    ForEach(overview.sensorCalibration) { sensor in
                        DisclosureGroup("\(sensor.sensorType) · \(sensor.status)") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(sensor.freshness == "unknown" ? "Freshness unknown" : sensor.freshness.capitalized)
                                if let score = sensor.qualityScore { Text("Quality score: \(score.formatted())") }
                                BiometricProfileDate(title: "Created", milliseconds: sensor.createdAtMs)
                                if let expires = sensor.expiresAtMs { BiometricProfileDate(title: "Expires", milliseconds: expires) }
                                if let start = sensor.sourceWindowStartMs { BiometricProfileDate(title: "Measured from", milliseconds: start) }
                                if let end = sensor.sourceWindowEndMs { BiometricProfileDate(title: "Measured until", milliseconds: end) }
                            }.padding(.top, 8)
                        }
                    }
                    ForEach(overview.limitations, id: \.self) { Text($0).foregroundStyle(Theme.text2) }
                }.font(.footnote).cardStyle()
            }
        }
    }
}

struct BiometricProfileRecoveryCard: View {
    let model: BiometricProfilesWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore a profile").font(.headline)
            Text("Review changes before requesting system defaults or the exact previous profile.").font(.footnote).foregroundStyle(Theme.text2)
            NavigationLink("Review system defaults") { BiometricProfileReviewScreen(model: model, action: .reset, target: nil) }
                .disabled(!model.canStartMutation || model.overview == nil).accessibilityIdentifier("profiles.reset")
            NavigationLink("Review previous profile") { BiometricProfileReviewScreen(model: model, action: .rollback, target: nil) }
                .disabled(!model.canStartMutation || (model.overview?.desired.binding.generation ?? 0) == 0).accessibilityIdentifier("profiles.rollback")
        }.cardStyle()
    }
}

struct BiometricProfileValue: View {
    let title: String
    let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(Theme.text2); Text(value).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
    }
}
struct BiometricProfileIdentity: View {
    let title: String
    let value: String
    var body: some View { VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(Theme.text2); Text(value).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
}
struct BiometricProfileError: View {
    let error: String
    var body: some View { Text(error).font(.footnote).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true) }
}
struct BiometricProfileDate: View {
    @Environment(SettingsManager.self) private var settings
    let title: String
    let milliseconds: Double
    @AppStorage("podTimeFormat") private var timeFormat = "12h"
    private var formatted: String {
        guard milliseconds.isFinite else { return "Unavailable" }
        let formatter = DateFormatter()
        formatter.locale = DevicePreferences.clockLocale(format: timeFormat)
        formatter.timeZone = TimeZone(identifier: settings.timeZone)
        formatter.setLocalizedDateFormatFromTemplate(timeFormat == "24h" ? "yMMMdHHmm" : "yMMMdhmm")
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
    var body: some View { BiometricProfileValue(title, value: formatted) }
}
struct BiometricProfileReceipts: View {
    let receipts: [BiometricRuntimeReceipt]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(receipts) { receipt in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(BiometricProfileLabels.component(receipt.component)) · \(BiometricProfileLabels.state(receipt.state))").font(.subheadline)
                    Text("Generation \(receipt.generation)")
                    BiometricProfileDate(title: "Heartbeat", milliseconds: receipt.heartbeatAtMs)
                    if let boundary = receipt.effectiveSampleTimeMs { BiometricProfileDate(title: "Effective boundary", milliseconds: boundary) }
                    if let error = receipt.error { BiometricProfileError(error: error) }
                    BiometricProfileIdentity(title: "Applied hash", value: receipt.appliedHash)
                }
            }
        }.font(.footnote).padding(.top, 8)
    }
}
