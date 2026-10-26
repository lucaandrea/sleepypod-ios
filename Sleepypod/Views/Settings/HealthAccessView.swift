import SwiftUI

struct HealthAccessView: View {
    @Environment(HealthSyncService.self) private var health
    @Environment(UserProfile.self) private var profile
    @Environment(ScheduleManager.self) private var schedule
    @Environment(SettingsManager.self) private var settings
    @Environment(\.openURL) private var openURL
    @State private var requesting = false
    @State private var confirmRebuild = false
    @State private var rebuildFailed = false
    @AppStorage("ownerConnectionRevision") private var connectionRevision = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("podIPAddress") private var host = ""
    private var scope: String { [connectionRevision, backend, endpoint, host, profile.defaultSide.rawValue].joined(separator: "|") }
    private var receiptPrefix: String { "\(settings.podID)-\(profile.defaultSide.rawValue)-" }
    private var receipts: [HealthSyncService.Receipt] { health.receipts.filter { $0.key.hasPrefix(receiptPrefix) }.map(\.value) }
    private var failures: [String] { health.failures.filter { $0.key.hasPrefix(receiptPrefix) }.map(\.value) }
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 30

    var body: some View {
        @Bindable var health = health
        @Bindable var profile = profile
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "heart").font(.system(size: 24)).foregroundStyle(Theme.red)
                        .frame(width: 56, height: 56)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Theme.border2, lineWidth: 1))
                        .accessibilityHidden(true)
                    Text("Sync with Apple Health").font(.system(size: titleSize, weight: .bold)).tracking(-0.5)
                    Text("Choose which records this iPhone writes to Health. Recorded time in bed is separate from sleep stages estimated on this iPhone.")
                        .font(.subheadline).foregroundStyle(Theme.text2).lineSpacing(3)
                    Text("These comparisons are calculated on this iPhone using your Health records and readings fetched from your Pod. Optional personal reports ask you to review evidence and approve sharing separately.")
                        .font(.footnote).foregroundStyle(Theme.text2).lineSpacing(3)
                }
                .padding(.horizontal, 8)
                VStack(alignment: .leading, spacing: 16) {
                    GroupedSection("WRITE") {
                        GroupedCard {
                            SettingsRow("Time in bed", subtitle: "Reported presence, preserving exits", height: 64) {
                                Toggle("Time in bed", isOn: $health.preferences.presence).labelsHidden().accessibilityIdentifier("health.presence")
                            }
                            SettingsRow("Estimated sleep stages", subtitle: "Analyzed on this iPhone; not a clinical measurement", height: 72) {
                                Toggle("Estimated sleep stages", isOn: $health.preferences.sleep).labelsHidden().accessibilityIdentifier("health.stages")
                            }
                            SettingsRow("Heart rate") { Toggle("Heart rate", isOn: $health.preferences.heartRate).labelsHidden() }
                            SettingsRow("Heart rate variability", subtitle: "Only recorded SDNN measurements", height: 64) { Toggle("Heart rate variability", isOn: $health.preferences.hrv).labelsHidden() }
                            SettingsRow("Respiratory rate") { Toggle("Respiratory rate", isOn: $health.preferences.respiration).labelsHidden() }
                        }
                    }
                    GroupedSection("READ") {
                        GroupedCard {
                            SettingsRow("Sleep schedule", subtitle: "Sets bedtime and wake in Schedule", height: 56) {
                                Toggle("Sleep schedule", isOn: $health.preferences.readSleep).labelsHidden()
                            }
                            SettingsRow("Heart rate, HRV, breathing", subtitle: "Compares the pod with your Apple Watch", height: 56) {
                                Toggle("Heart rate, HRV, breathing", isOn: $health.preferences.readVitals).labelsHidden()
                            }
                        }
                    }
                    GroupedSection("THIS iPHONE") {
                        GroupedCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Linked Health side").font(.callout)
                                Picker("Linked Health side", selection: $profile.defaultSide) {
                                    ForEach(Side.allCases, id: \.self) { Text(settings.sideName(for: $0)).tag($0) }
                                }.pickerStyle(.segmented).accessibilityIdentifier("health.side")
                                Text("Choose the person using this iPhone. Browsing the other side's controls does not change Health export.")
                                    .font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                            }.padding(16)
                            SettingsRow("Sync this iPhone's side") {
                                Toggle("Sync this iPhone's side", isOn: $health.enabled).labelsHidden()
                            }
                        }
                    }
                    if health.authorizationDenied { deniedNote } else { allowButton.padding(.top, 8) }
                    syncStatus
                    if let error = health.authorizationError {
                        Text(error).font(.footnote).foregroundStyle(Theme.amber).padding(.horizontal, 16)
                    }
                }
                .padding(.top, 28)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background).tint(Theme.green)
        .navigationTitle("Apple Health").navigationBarTitleDisplayMode(.inline)
        .onChange(of: scope) { _, _ in rebuildFailed = false; health.authorizationError = nil }
        .confirmationDialog("Rebuild Apple Health data?", isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button("Rebuild", role: .destructive) { rebuild() }
        } message: {
            Text("Rewrites up to \(HealthSyncService.rebuildDays) days for \(settings.sideName(for: profile.defaultSide)) on this Pod, then removes its older sleepypod samples. Other sides, Pods, Apple Watch and other apps stay untouched. Keep the app open until it finishes.")
        }
    }

    /// What actually reached Health, so a sync can be checked on a real device.
    private var syncStatus: some View {
        GroupedSection("SYNC") {
            GroupedCard {
                SettingsRow("Side", icon: "bed.double") { RowValue(settings.sideName(for: profile.defaultSide)) }
                SettingsRow("Records saved", icon: "heart", iconColor: Theme.red) { RowValue("\(receipts.count)", mono: true) }
                SettingsRow("Last saved", icon: "clock") {
                    RowValue(receipts.map(\.date).max()?.formatted(date: .abbreviated, time: .shortened) ?? "Never", mono: true)
                }
                ForEach(Array(Set(failures)).sorted(), id: \.self) { message in
                    let count = failures.filter { $0 == message }.count
                    SettingsRow(message, icon: "exclamationmark.triangle", iconColor: Theme.amber, titleFont: .footnote) {
                        RowValue(count == 1 ? "1 record" : "\(count) records", mono: true)
                    }
                }
                Button {
                    Haptics.light()
                    let original = scope
                    Task {
                        await health.syncRecent(api: HealthSyncService.frozenClient(), podID: settings.podID,
                                                side: profile.defaultSide, demo: APIBackend.current.isDemo)
                        guard original == scope, !Task.isCancelled else { return }
                        if failures.isEmpty && health.authorizationError == nil { Haptics.success() } else { Haptics.warning() }
                    }
                } label: {
                    SettingsRow(health.isSyncing ? "Syncing…" : "Sync last 7 days now", icon: "arrow.triangle.2.circlepath") {
                        if health.isSyncing { ProgressView() }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("health.syncRecent")
                .disabled(health.isSyncing || !health.enabled || APIBackend.current.isDemo)
                Button {
                    Haptics.light()
                    confirmRebuild = true
                } label: {
                    SettingsRow(rebuildTitle, icon: "arrow.counterclockwise", iconColor: Theme.amber) {
                        if health.rebuildProgress != nil { ProgressView() }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("health.rebuild")
                .disabled(health.isSyncing || !health.enabled || APIBackend.current.isDemo)
            }
            if rebuildFailed {
                Text("The rebuild stopped before every record was rewritten, so older Health data was kept. Fix the errors above and try again.")
                    .font(.footnote).foregroundStyle(Theme.amber).padding(.horizontal, 16)
            }
            if APIBackend.current.isDemo {
                Text("Demo mode never writes to Apple Health. Connect a pod to sync.")
                    .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16)
            }
        }
    }

    private var rebuildTitle: String {
        guard let progress = health.rebuildProgress else { return "Rebuild last \(HealthSyncService.rebuildDays) days" }
        return progress.total == 0 ? "Finding nights…" : "Rebuilding \(progress.done) of \(progress.total) nights…"
    }

    private func rebuild() {
        rebuildFailed = false
        let original = scope
        Task {
            let rebuilt = await health.rebuild(api: HealthSyncService.frozenClient(), podID: settings.podID,
                                               side: profile.defaultSide, demo: APIBackend.current.isDemo)
            guard original == scope, !Task.isCancelled else { return }
            rebuildFailed = !rebuilt
            if rebuilt { Haptics.success() } else { Haptics.warning() }
        }
    }

    private var allowButton: some View {
        Button {
            Haptics.light()
            requesting = true
            let original = scope
            Task {
                defer { requesting = false }
                if await health.requestAuthorization() {
                    guard original == scope, !Task.isCancelled else { return }
                    Haptics.success()
                    if health.preferences.readSleep { await importSchedule() }
                } else {
                    Haptics.warning()
                }
            }
        } label: {
            BusyLabel(title: "Allow Health access", busyTitle: "Requesting access…", isBusy: requesting)
        }
        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("health.authorize").disabled(requesting || APIBackend.current.isDemo)
    }

    /// iOS shows the Health sheet once; after a refusal the only way back in is the Settings app.
    private var deniedNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Health access is turned off for sleepypod. Turn it on in Settings under Health, Data Access & Devices.")
                .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                Haptics.light()
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.top, 8)
    }

    private func importSchedule() async {
        let original = scope
        guard let times = await health.inferredSchedule(), original == scope, !Task.isCancelled else { return }
        schedule.selectedSide = profile.defaultSide == .left ? .left : .right
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        await schedule.fetchSchedules()
        guard original == scope, !Task.isCancelled else { return }
        await schedule.updateBedtime(formatter.string(from: times.bed))
        guard original == scope, !Task.isCancelled else { return }
        if var power = schedule.currentDailySchedule?.power {
            power.off = formatter.string(from: times.wake)
            await schedule.updatePowerSchedule(power)
        }
    }
}
