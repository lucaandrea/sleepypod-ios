import SwiftUI

struct DaytimeContextScreen: View {
    @State private var workspace = DaytimeContextWorkspace.shared
    @State private var example = DaytimeContextPresentation.example()
    @State private var exampleNotice = DaytimeContextPresentation.exampleNotice()
    @State private var before = Date.now
    @State private var confirmForget = false
    @State private var choosingTime = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(PersonalWorkspaceBoundary.preferenceKey) private var personal = false
    private var archive: DaytimeContextArchive { AppMode.isDemo ? example : workspace.archive }
    private var snapshot: DaytimeContext? { archive.snapshot }
    private var notice: String? { AppMode.isDemo ? exampleNotice : workspace.message }
    private var summary: DaytimeContextSummary? {
        guard let snapshot else { return nil }
        return try? .make(snapshot: snapshot, bedtime: before)
    }

    var body: some View {
        FeaturePage(title: "Daytime context") {
            VStack(alignment: .leading, spacing: 22) {
                if personal {
                    Text("Daytime context belongs to the person using this device. The installation owner’s Health history is unavailable in a personal workspace.")
                } else {
                    introduction
                    if let snapshot {
                        window(snapshot)
                        if let summary { observations(summary) }
                        else { Text("This window could not be verified. Refresh context or choose an earlier time.").accessibilityIdentifier("context.invalid") }
                    }
                    if let message = notice {
                        Text(message).font(.subheadline).accessibilityIdentifier("context.message")
                    }
                    privacy
                }
            }.frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task(id: scenePhase) {
            if scenePhase == .active, !personal {
                if !AppMode.isDemo { await workspace.refreshOnActivation() }
                alignWindow()
            } else if scenePhase == .background { workspace.suspend() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if !AppMode.isDemo { workspace.restore() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in workspace.suspend() }
        .onDisappear { workspace.suspend() }
        .onChange(of: snapshot?.importedAt) { alignWindow() }
        .sheet(isPresented: $choosingTime) {
            if let snapshot {
                NavigationStack {
                    DatePicker("Bedtime", selection: $before, in: ...min(.now, snapshot.importedAt), displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.wheel).labelsHidden().padding()
                        .accessibilityIdentifier("context.time.picker")
                        .navigationTitle("Review before").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { choosingTime = false }.accessibilityIdentifier("context.time.done")
                        } }
                }.environment(\.timeZone, TimeZone(identifier: snapshot.timeZone) ?? .current)
                    .presentationDetents([.medium, .large])
            }
        }
        .confirmationDialog("Turn off daytime context and remove its local copy?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Turn off & remove", role: .destructive) { workspace.forget() }
        } message: { Text("Your Apple Health records, sleep history and reports remain unchanged.") }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            if AppMode.isDemo { Label("Example · not your Health data", systemImage: "play.circle").font(.subheadline) }
            Text("Your day before bed").font(.title2.bold())
            Text("Review recorded workouts, activity and earlier wrist temperature alongside your sleep. Start by choosing which Health data to read.")
                .foregroundStyle(Theme.text2)
            Button(archive.enabled ? "Refresh context" : "Choose Health data") {
                Task { await workspace.importContext(requestPermission: !archive.enabled) }
            }.buttonStyle(PrimaryButtonStyle()).disabled(workspace.busy || AppMode.isDemo)
                .accessibilityIdentifier("context.refresh")
            if workspace.busy { ProgressView("Reading accessible context…") }
            if !archive.enabled {
                Text("Optional · off until you choose. Up to 90 days of accessible records stay encrypted on this device.")
                    .font(.subheadline).foregroundStyle(Theme.text2).accessibilityIdentifier("context.off")
            }
            Text("This is context for comparison. A workout alone does not mean you need a colder bed.")
                .font(.subheadline).foregroundStyle(Theme.text2)
        }
    }

    private func window(_ snapshot: DaytimeContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Choose an evening to review").font(.headline)
            Button { choosingTime = true } label: {
                bedtimeLabel.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.accessibilityIdentifier("context.before")
            Text("The 24 elapsed hours before this time · \(snapshot.timeZone). Choose your bedtime to inspect the preceding day.")
                .font(.caption).foregroundStyle(Theme.text2)
            Text("Last read \(contextDate(snapshot.importedAt)).")
                .font(.caption).foregroundStyle(Theme.text2).accessibilityIdentifier("context.imported")
        }.environment(\.timeZone, TimeZone(identifier: snapshot.timeZone) ?? .current)
    }

    @ViewBuilder private var bedtimeLabel: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Before")
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right").font(.caption)
                }
                Text(before, format: .dateTime.month(.abbreviated).day().year())
                Text(before, format: .dateTime.hour().minute())
            }.fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Before")
                Spacer(minLength: 12)
                Text(before, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.caption)
            }
        }
    }

    private func observations(_ summary: DaytimeContextSummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            Text("Recorded activity").font(.headline)
            Text("Returned samples, separated by source. These totals may not cover your whole day; missing records remain unknown.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            if summary.groups.isEmpty {
                Text("No usable activity records in this window.").accessibilityIdentifier("context.empty")
            }
            ForEach(Array(summary.groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.kind.title).font(.headline)
                    Text(group.total.map { group.kind.formatted($0) } ?? "No unambiguous total")
                        .font(.title3.weight(.semibold)).foregroundStyle(Theme.text1)
                    Text("\(group.source.name)\(group.source.device.map { " · " + $0 } ?? "")").font(.subheadline)
                    Text("\(group.observationCount) included records\(group.latestEnd.map { " · last ended " + contextDate($0, includeDate: false) } ?? "")")
                        .font(.caption).foregroundStyle(Theme.text2)
                    if group.excludedOverlaps > 0 {
                        Text("\(group.excludedOverlaps) overlapping records excluded.").font(.caption)
                    }
                }.accessibilityElement(children: .combine).accessibilityIdentifier("context.group.\(group.kind.rawValue)")
            }
            if !summary.emptyKinds.isEmpty {
                Text("No returned records: \(summary.emptyKinds.map(\.title).joined(separator: ", ")). Access restrictions can also produce empty results.")
                    .font(.caption).foregroundStyle(Theme.text2)
            }
            if !summary.unavailableKinds.isEmpty {
                Text("Unavailable for this window: \(summary.unavailableKinds.map(\.title).joined(separator: ", ")). Refresh or choose a window covered by the import.")
                    .font(.subheadline).accessibilityIdentifier("context.unavailable")
            }
            Divider()
            Text("Previous wrist temperature").font(.headline)
            Text("A nightly aggregate, not live body temperature. Only a recording that ended before your selected time is shown.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            if summary.previousWrist.isEmpty { Text("No prior wrist reading returned within seven days.").accessibilityIdentifier("context.wrist.empty") }
            ForEach(Array(summary.previousWrist.enumerated()), id: \.offset) { _, wrist in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(wrist.absoluteCelsius.formatted(.number.precision(.fractionLength(1)))) °C absolute wrist temperature").font(.headline)
                    Text(wrist.source.name).font(.subheadline)
                    Text("\(contextDate(wrist.start)) – \(contextDate(wrist.end))")
                        .font(.caption).foregroundStyle(Theme.text2)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("context.wrist")
            }
            Text("Apple Health may show change from a baseline. This view preserves the absolute value returned by HealthKit.")
                .font(.caption).foregroundStyle(Theme.text2)
        }.environment(\.timeZone, TimeZone(identifier: snapshot?.timeZone ?? "") ?? .current)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Your context stays yours").font(.headline)
            Text("No context is sent to an AI provider or the Pod here, and no bed settings change. Reading again replaces this local snapshot, including records that are no longer returned by Health.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            if archive.enabled {
                Text("Context can refresh when you open this screen or return to the app. iOS may delay reads while your device is locked.")
                    .font(.caption).foregroundStyle(Theme.text2)
                Button("Review Health access") { Task { await workspace.importContext(requestPermission: true) } }
                    .frame(minHeight: 44).disabled(workspace.busy || AppMode.isDemo).accessibilityIdentifier("context.access")
            }
            if archive.enabled || (AppMode.isDemo ? exampleNotice != nil : workspace.canRemoveLocalCopy) {
                Button("Turn off & remove local context", role: .destructive) { confirmForget = true }
                    .frame(minHeight: 44).disabled(AppMode.isDemo).accessibilityIdentifier("context.remove")
            }
            Link("About Apple Watch wrist temperature", destination: URL(string: "https://support.apple.com/en-us/102674")!)
                .frame(minHeight: 44)
        }
    }
    private func alignWindow() {
        guard let end = snapshot?.reads.map(\.end).min(), before > end else { return }
        before = end
    }

    // Interpolated strings need the archive's zone explicitly when the phone has travelled.
    private func contextDate(_ date: Date, includeDate: Bool = true) -> String {
        date.formatted(Date.FormatStyle(date: includeDate ? .abbreviated : .omitted, time: .shortened,
                                       timeZone: TimeZone(identifier: snapshot?.timeZone ?? "") ?? .current))
    }
}

extension DaytimeContext.Kind {
    var title: String {
        switch self {
        case .workout: "Workout time"
        case .exerciseMinutes: "Exercise minutes"
        case .activeEnergyKilocalories: "Active energy"
        case .steps: "Steps"
        case .sleepingWristCelsius: "Sleeping wrist temperature"
        }
    }
    func formatted(_ value: Double) -> String {
        switch self {
        case .workout, .exerciseMinutes: value.formatted(.number.precision(.fractionLength(0...1))) + " min"
        case .activeEnergyKilocalories: value.formatted(.number.precision(.fractionLength(0))) + " kcal"
        case .steps: value.formatted(.number.precision(.fractionLength(0))) + " steps"
        case .sleepingWristCelsius: value.formatted(.number.precision(.fractionLength(1))) + " °C"
        }
    }
}
