import SwiftUI

/// Unified active curve — either from a run-once session or today's recurring schedule.
struct ActiveCurve: Identifiable {
    enum Source { case runOnce, schedule }
    let id: String
    let source: Source
    let session: RunOnceSession? // non-nil for run-once
    let setPoints: [RunOnceSetPoint]
    let wakeTime: String
    let bedtime: String
}

struct TempScreen: View {
    @Environment(DeviceManager.self) private var deviceManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(ScheduleManager.self) private var scheduleManager

    @Environment(SensorStreamService.self) private var sensor
    @Environment(UserProfile.self) private var profile
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    @AppStorage("podURL") private var podURL = ""
    @AppStorage("podIPAddress") private var podIP = ""
    @AppStorage("apiBackend") private var backend = ""
    private var nightScope: String { "\(profile.tempControl)|\(scenePhase)|\(backend)|\(podURL)|\(podIP)|\(ownerRevision)|\(settingsManager.timeZone)|\(settingsManager.settings?.defaultScheduleEndAction?.rawValue ?? "turn_off")" }
    @State private var curveError: String?
    @State private var activeCurve: ActiveCurve?
    @State private var nightPhases = NightPhasesStore()
    @State private var stepperTab: StepperTab = .now

    private func stopCurve() {
        guard let curve = activeCurve else { return }
        let side = deviceManager.selectedSide.primarySide

        if curve.source == .runOnce {
            Task {
                let api = APIBackend.current.createClient()
                do {
                    try await api.cancelRunOnce(side: side)
                    if APIBackend.current == .freeSleep {
                        let powerOff = SideStatusUpdate(isOn: false)
                        var update = DeviceStatusUpdate()
                        if side == .left { update.left = powerOff } else { update.right = powerOff }
                        try await api.updateDeviceStatus(update)
                    }
                    await deviceManager.fetchStatus()
                    curveError = nil
                    withAnimation { activeCurve = nil }
                } catch { curveError = error.localizedDescription }

            }
        }
    }

    private func fetchActiveCurve() async {
        let side = deviceManager.selectedSide.primarySide

        // 1. Check for run-once session (overrides recurring)
        if let session = try? await APIBackend.current.createClient().getActiveRunOnce(side: side) {
            activeCurve = ActiveCurve(
                id: "runonce-\(session.id)",
                source: .runOnce,
                session: session,
                setPoints: session.setPoints,
                wakeTime: session.wakeTime,
                bedtime: session.setPoints.first?.time ?? "22:00"
            )
            return
        }

        // 2. Fall back to today's recurring schedule
        if let schedules = scheduleManager.schedules {
            let today = currentDayOfWeek()
            let sideSchedule = schedules.schedule(for: side)
            let daily = sideSchedule[today]

            if !daily.temperatures.isEmpty {
                // Sort by offset-from-bedtime so an overnight curve renders left-to-right
                // as evening → morning. String-sorting ("03:00" < "22:00") would put the
                // wake-side points first and push bedtime points ~20h into the chart.
                let bedtime = daily.power.enabled ? daily.power.on : "22:00"
                let bedMin = clockMinutesOfDay(bedtime)
                let points = daily.temperatures
                    .sorted { lhs, rhs in
                        offsetFromBedtime(lhs.key, bedtime: bedMin)
                            < offsetFromBedtime(rhs.key, bedtime: bedMin)
                    }
                    .map { RunOnceSetPoint(time: $0.key, temperature: Double($0.value)) }
                let wake = daily.power.enabled ? daily.power.off : "07:00"
                activeCurve = ActiveCurve(
                    id: "schedule-\(side.rawValue)-\(today.rawValue)",
                    source: .schedule,
                    session: nil,
                    setPoints: points,
                    wakeTime: wake,
                    bedtime: bedtime
                )
                return
            }
        }

        activeCurve = nil
    }

    private func currentDayOfWeek() -> DayOfWeek {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: settingsManager.timeZone) ?? .current
        let weekday = calendar.component(.weekday, from: Date())
        // Calendar weekday: 1=Sunday, 2=Monday, ...
        let days: [DayOfWeek] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        return days[weekday - 1]
    }

    private func clockMinutesOfDay(_ time: String) -> Int {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return 0 }
        return h * 60 + m
    }

    private func offsetFromBedtime(_ time: String, bedtime: Int) -> Int {
        (clockMinutesOfDay(time) - bedtime + 1440) % 1440
    }

    /// Short "Just now" / "12s ago" / "2m ago" label for the last-updated indicator.
    static func relativeTime(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }

    private var sideName: String {
        if deviceManager.isLinked { return "\(settingsManager.leftName) + \(settingsManager.rightName)" }
        return settingsManager.sideName(for: deviceManager.selectedSide.primarySide)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if deviceManager.isConnected {
                    layoutToolbar
                }
                Group {
                if deviceManager.isConnected {
                    if profile.temperatureLayout == .stage {
                        TemperatureStageScreen()
                    } else { switch profile.tempControl {
                    case .dial, .stepper: centeredControl
                    case .slider:
                        TempSliderView(curve: activeCurve, profileName: activeCurve.map { profileName($0.setPoints) } ?? "")
                    case .sides:
                        ScrollView { VStack(spacing: 16) { TemperatureNoticesView(); BothSidesView(curve: activeCurve) } }
                            .refreshable { await deviceManager.fetchStatus(); await fetchActiveCurve() }
                    } }
                } else {
                    DisconnectedTabView(tab: "Temp")
                }
                }
            }
            .background(Theme.background)
            .navigationTitle(profile.tempControl == .sides ? "Bed" : "")
            .navigationBarTitleDisplayMode(profile.tempControl == .sides ? .large : .inline)
            .settingsToolbar()
            .toolbar {
                switch profile.tempControl {
                case .dial, .stepper:
                    ToolbarItem(placement: .topBarLeading) { header }
                        .sharedBackgroundVisibility(.hidden)
                case .slider:
                    ToolbarItem(placement: .topBarLeading) { sideMenu }
                case .sides:
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(deviceManager.isLinked ? "Unlink sides" : "Link sides", systemImage: "link") {
                            Haptics.tap()
                            deviceManager.toggleLink()
                        }
                        .tint(deviceManager.isLinked ? Theme.text1 : Theme.text2)
                    }
                }
            }
        }
        .task(id: nightScope) {
            nightPhases.suspend()
            guard scenePhase == .active, profile.tempControl == .stepper else { return }
            let client: (any NightPhaseClient)?
            if APIBackend.current.isDemo { client = DemoNightPhaseClient(api: APIBackend.current.createClient(), scenario: DebugRoute.temperatureContextScenario) }
            else if APIBackend.current == .sleepypodCore, let transport = try? CoreRESTClient.configured() { client = CoreNightPhaseClient(transport: transport) }
            else { client = nil }
            nightPhases.configure(client: client, timezone: settingsManager.timeZone, endAction: settingsManager.settings?.defaultScheduleEndAction ?? .turnOff)
            await nightPhases.load([.left, .right])
        }
        .onDisappear { nightPhases.suspend() }
        .onChange(of: nightPhases.phases) { _, values in
            guard !values.isEmpty else { return }
            Task { await scheduleManager.fetchSchedules(); await fetchActiveCurve() }
        }
        .task {
            await settingsManager.fetchSettings()
            await scheduleManager.fetchSchedules()
            await fetchActiveCurve()
            if deviceManager.isConnected { sensor.connect() }
        }
        .task(id: deviceManager.selectedSide) { await fetchActiveCurve() }
        .onReceive(NotificationCenter.default.publisher(for: .switchToTempTab)) { _ in Task { await fetchActiveCurve() } }
    }

    private var layoutToolbar: some View {
        @Bindable var profile = profile
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Picker("Temperature layout", selection: $profile.temperatureLayout) {
                Label("Cards", systemImage: "square.grid.2x2").tag(TemperatureLayout.cards)
                Label("Stage", systemImage: "cube").tag(TemperatureLayout.stage)
            }.pickerStyle(.segmented).frame(maxWidth: 240)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Button("All off", systemImage: "power") { deviceManager.allOff() }
                .font(.subheadline).buttonStyle(.bordered)
                .disabled(deviceManager.deviceStatus.map { !$0.left.isOn && !$0.right.isOn } ?? true)
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Dial or Night & Dawn stepper, with the side switcher above and today's context below.
    private var centeredControl: some View {
        ScrollView {
            VStack(spacing: 0) {
                TemperatureNoticesView()
                SideSelectorView()
                if profile.tempControl == .stepper {
                    TempStepperView(store: nightPhases, tab: $stepperTab).padding(.top, 20)
                    TempControlsView(powerOnly: true).padding(.top, 20)
                } else {
                    TemperatureDialView().padding(.top, 28)
                    TempControlsView().padding(.top, 14)
                }
                TemperatureOwnershipView().padding(.top, 24)
                environmentLine.padding(.top, 20)
                if APIBackend.current != .freeSleep { NextAlarmCard(side: deviceManager.selectedSide.primarySide).padding(.top, 20) }
                VStack(spacing: 12) {
                    if let curveError {
                        Text(curveError).font(.footnote).foregroundStyle(Theme.amber)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let curve = activeCurve {
                        if let session = curve.session {
                            RunOnceActiveBanner(session: session, onCancel: stopCurve, compact: true)
                        } else {
                            tonightCard(curve)
                        }
                    }
                }
                .padding(.top, 24)
                if APIBackend.current != .freeSleep {
                    TemperatureContextCards(side: deviceManager.selectedSide.primarySide).padding(.top, 20)
                }
            }
            .padding(.horizontal, profile.tempControl == .stepper ? 16 : 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .refreshable {
            await deviceManager.fetchStatus()
            await fetchActiveCurve()
            if profile.tempControl == .stepper { await nightPhases.load([.left, .right]) }
        }
    }

    /// 1c puts the side picker in a glass menu instead of the segmented switcher.
    private var sideMenu: some View {
        Menu {
            Picker("Side", selection: Binding(
                get: { deviceManager.isLinked ? SideSelection.both : deviceManager.selectedSide },
                set: { selection in
                    if (selection == .both) != deviceManager.isLinked { deviceManager.toggleLink() }
                    deviceManager.selectSide(selection)
                }
            )) {
                Text(settingsManager.leftName).tag(SideSelection.left)
                Label("Both", systemImage: "link").tag(SideSelection.both)
                Text(settingsManager.rightName).tag(SideSelection.right)
            }
        } label: {
            HStack(spacing: 8) {
                Text(sideName).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text1)
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 6)
        }
        .accessibilityLabel("Side, \(sideName)")
    }

    private var header: some View {
        let side = deviceManager.selectedSide.primarySide
        let occupied = deviceManager.isLinked
            ? (sensor.isOccupied(side: .left) || sensor.isOccupied(side: .right))
            : sensor.isOccupied(side: side)
        let place = deviceManager.isLinked ? "BOTH" : side.rawValue.uppercased()
        return VStack(alignment: .leading, spacing: 3) {
            Text(sideName).font(.title2.bold()).tracking(-0.3).lineLimit(1)
            HStack(spacing: 6) {
                if occupied { StatusDot() }
                Eyebrow("\(place) · \(sensor.presenceLabel(sides: deviceManager.isLinked ? Side.allCases : [side]))")
                if APIBackend.current.isDemo && !DebugRoute.marketingCapture { Eyebrow("· DEMO", color: Theme.amber) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private var environmentLine: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 18))
        return layout {
            let temps = deviceManager.selectedSide.primarySide == .left ? sensor.leftTemps : sensor.rightTemps
            if RoomSnapshot.isFresh(sensor.bedTempUpdatedAt, now: .now), let ambient = temps?.amb, ambient.isFinite, ambient > -100 {
                let format = settingsManager.temperatureFormat == .relative ? .fahrenheit : settingsManager.temperatureFormat
                Label {
                    Text("\(TemperatureConversion.displayTemp(Int((ambient * 9 / 5 + 32).rounded()), format: format)) inside")
                } icon: { Image(systemName: "house") }
            }
            if let status = deviceManager.currentSideStatus, status.isOn, status.secondsRemaining > 0 {
                Label { Text(DisplayTime.duration(status.secondsRemaining)) } icon: { Image(systemName: "timer") }
                    .accessibilityLabel("Turns off in \(DisplayTime.duration(status.secondsRemaining))")
            }
        }
        .labelStyle(EnvironmentLabelStyle())
        .font(.mono(12, relativeTo: .caption)).foregroundStyle(Theme.text2)
        .frame(minHeight: 16)
    }

    private func tonightCard(_ curve: ActiveCurve) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Eyebrow("TONIGHT · \(profileName(curve.setPoints).uppercased())")
                    Spacer(minLength: 8)
                    range(curve)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("TONIGHT · \(profileName(curve.setPoints).uppercased())")
                    range(curve)
                }
            }
            TemperatureCurve(points: curve.setPoints, bedtime: curve.bedtime, wake: curve.wakeTime, compact: true)
        }
        .cardStyle()
    }

    private func range(_ curve: ActiveCurve) -> some View {
        Text("\(DisplayTime.clock(curve.bedtime)) → \(DisplayTime.clock(curve.wakeTime))")
            .font(.mono(12, relativeTo: .caption)).foregroundStyle(Theme.text2)
    }

    private func profileName(_ points: [RunOnceSetPoint]) -> String {
        let values = points.map { Int($0.temperature) }.sorted()
        return SleepProfile.allCases.first { $0.temperatures(for: values.count).sorted() == values }?.rawValue ?? "Custom"
    }
}

private struct EnvironmentLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 12)); configuration.title }
    }
}
