import SwiftUI
import FreeSleepKit
import AppIntents

struct UnifiedAppIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [FreeSleepIntentsPackage.self] }
}

@main
struct SleepypodApp: App {
    @State private var deviceManager: DeviceManager
    @State private var scheduleManager: ScheduleManager
    @State private var metricsManager: MetricsManager
    @State private var statusManager: StatusManager
    @State private var settingsManager: SettingsManager
    @State private var household: HouseholdWorkspace
    @State private var alarms = AlarmWorkspace()
    @State private var curves = CurveWorkspace()
    @State private var podDiscovery = PodDiscovery()
    @State private var userProfile = UserProfile()
    @State private var sensorStream = SensorStreamService()
    @State private var notificationRelay = NotificationRelay()
    @State private var alertInbox = AlertInboxSession()
    @State private var homeRoom = HomeRoomSession()
    @State private var bedroom = BedroomSession()
    @State private var nativeActions: NativeActionSession
    @State private var healthSync: HealthSyncService
    @State private var stageModels: StageModelStore
    @State private var watchMotion = WatchMotionReceiver()
    @State private var snoreCapture = SnoreCaptureService()

    init() {
        #if DEBUG
        let household = PersonalHistoryPreview.make() ?? ArrangementReviewPreview.make() ?? PersonalRoutinePreview.make() ?? PersonalTemperaturePreview.make() ?? HouseholdPreview.make() ?? HouseholdWorkspace()
        #else
        let household = HouseholdWorkspace()
        #endif
        _household = State(initialValue: household)
        UnifiedRuntime.initialize()
        #if DEBUG
        if APIBackend.current.isDemo && ProcessInfo.processInfo.arguments.contains("--reset-base-preferences") {
            for key in ["mattress", "simple", "instantPresets", "linked", "cards", "scope"] {
                UserDefaults.standard.removeObject(forKey: "base.\(key)")
            }
        }
        #endif
        let client = APIBackend.current.createClient()
        let device = DeviceManager(api: client)
        let schedule = ScheduleManager(api: client)
        let metrics = MetricsManager(api: client)
        let status = StatusManager(api: client)
        let settings = SettingsManager(api: client)

        _deviceManager = State(initialValue: device)
        _scheduleManager = State(initialValue: schedule)
        _metricsManager = State(initialValue: metrics)
        _statusManager = State(initialValue: status)
        _settingsManager = State(initialValue: settings)
        // Wired here, not in a view task: a background-refresh launch syncs Health before any window appears,
        // and the receipt signature must already know which model stages the nights.
        let models = StageModelStore()
        let health = HealthSyncService()
        health.stageModels = models
        _stageModels = State(initialValue: models)
        _healthSync = State(initialValue: health)
        let actions = NativeActionSession.configured { try await health.syncLinkedThirtyDays() }
        _nativeActions = State(initialValue: actions)
        let bridge = actions.bridge
        AppDependencyManager.shared.add(dependency: bridge)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if household.active { HouseholdRootView() }
                else { ownerContent }
            }
                .environment(household)
                .preferredColorScheme(userProfile.appearance.colorScheme)
                .foregroundStyle(Theme.text1)
                .tint(Theme.text1)
                .task {
                    sensorStream.notificationRelay = notificationRelay
                    if !household.active { watchMotion.activate() }
                }
                .onChange(of: household.active) {
                    if household.active {
                        deviceManager.suspendConnection(); sensorStream.disconnect(); podDiscovery.stopBrowsing()
                        snoreCapture.stop(reason: "personal account opened")
                    } else { watchMotion.activate() }
                }
                .task(id: deviceManager.isConnected) {
                    // Keep first-install setup focused on local network access.
                    if !household.active && deviceManager.isConnected && !APIBackend.current.isDemo && !DebugRoute.marketingCapture {
                        await notificationRelay.requestPermission()
                    }
                }
        }
        .backgroundTask(.appRefresh("com.lucaandrea.freesleep.health.refresh")) {
            await UnifiedRuntime.backgroundHealth()
        }
        .backgroundTask(.appRefresh(HealthSyncService.backgroundTaskID)) { [healthSync] in
            // Queue the next wake-up first so a sync that runs out of time doesn't end the chain.
            HealthSyncService.scheduleBackgroundSync()
            await healthSync.syncInBackground()
        }
    }
    private var ownerContent: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--connection-fixture") { ConnectionRecoveryPreview() }
            else { ContentView() }
            #else
            ContentView()
            #endif
        }
            .environment(deviceManager).environment(scheduleManager).environment(alarms).environment(curves)
            .environment(metricsManager).environment(statusManager).environment(settingsManager).environment(podDiscovery)
            .environment(userProfile).environment(sensorStream).environment(notificationRelay).environment(alertInbox)
            .environment(homeRoom).environment(bedroom).environment(healthSync).environment(nativeActions)
            .environment(stageModels).environment(watchMotion).environment(snoreCapture)
    }
}

struct ContentView: View {
    @Environment(DeviceManager.self) private var deviceManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(PodDiscovery.self) private var podDiscovery
    @Environment(SensorStreamService.self) private var sensorStream
    @Environment(ScheduleManager.self) private var scheduleManager
    @Environment(AlarmWorkspace.self) private var alarms
    @Environment(CurveWorkspace.self) private var curves
    @Environment(AlertInboxSession.self) private var alertInbox
    @Environment(HomeRoomSession.self) private var homeRoom
    @Environment(BedroomSession.self) private var bedroom
    @Environment(MetricsManager.self) private var metricsManager
    @Environment(StatusManager.self) private var statusManager
    @Environment(HealthSyncService.self) private var healthSync
    @Environment(UserProfile.self) private var profile
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = Self.initialTab
    @State private var showWelcome = false
    @State private var connectionPath = ConnectionPathMonitor()
    @AppStorage("apiBackend") private var backendIdentity = ""
    @AppStorage("podURL") private var inboxOwnerURL = ""
    @AppStorage("podIPAddress") private var inboxPodHost = ""
    @AppStorage("ownerConnectionRevision") private var inboxOwnerRevision = ""
    private var inboxScope: String { "\(backendIdentity)|\(inboxOwnerURL)|\(inboxPodHost)|\(inboxOwnerRevision)" }

    private static var initialTab: String {
        switch DebugRoute.current {
        case "schedule": "schedule"
        case "sleep", "week", "weektrend", "month", "watch", "stages": "sleep"
        default: "temp"
        }
    }

    /// Outline glyphs in both states, as drawn in the source tab bar.
    private func tabLabel(_ title: String, _ symbol: String) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).environment(\.symbolVariants, .none) }
    }

    private var isConnected: Bool {
        deviceManager.isConnected
    }

    private var isDemo: Bool {
        APIBackend.current.isDemo
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab(value: "temp") {
                    TempScreen()
                } label: { tabLabel("Temp", "thermometer.medium") }
                Tab(value: "schedule") {
                    if isConnected { ScheduleScreen() }
                    else { NavigationStack { DisconnectedTabView(tab: "Schedule", selectedTab: $selectedTab).settingsToolbar() } }
                } label: { tabLabel("Schedule", "calendar") }
                Tab(value: "sleep") {
                    if isConnected { SleepScreen() }
                    else { NavigationStack { DisconnectedTabView(tab: "Sleep", selectedTab: $selectedTab).settingsToolbar() } }
                } label: { tabLabel("Sleep", "moon") }
            }
            .id(inboxScope)
            .tabBarMinimizeBehavior(.onScrollDown)
            .onChange(of: inboxScope) {
                alarms.configure(); curves.configure()
                if !isDemo, scenePhase == .active {
                    deviceManager.resumeConnection()
                    sensorStream.reconnect()
                }
            }
            .onChange(of: selectedTab) {
                Haptics.tap()
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToTempTab)) { notification in
                if let side = notification.object as? SideSelection {
                    deviceManager.selectedSide = side
                }
                selectedTab = "temp"
            }
            .onReceive(NotificationCenter.default.publisher(for: .leaveDemoMode)) { _ in leaveDemoMode() }
            .onReceive(NotificationCenter.default.publisher(for: .showSleepRecord)) { notification in
                guard let record = notification.object as? SleepRecord, let side = Side(rawValue: record.side) else { return }
                metricsManager.selectedSide = side
                metricsManager.sleepNavigation = SleepNavigationRequest(record: record)
                selectedTab = "sleep"
            }

        }
        .overlay(alignment: .top) { AlertForegroundBanner() }
        .task(id: "\(inboxScope)-\(scenePhase)") {
            alertInbox.configure(scope: inboxScope)
            guard let model = alertInbox.workspace else { return }
            model.isActive = scenePhase == .active
            if !model.isActive { model.dismissAnnouncements(); return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task(id: "room-\(inboxScope)-\(scenePhase)") {
            homeRoom.configure(scope: inboxScope)
            guard let model = homeRoom.workspace else { return }
            model.isActive = scenePhase == .active
            guard model.isActive else { return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task(id: "bedroom-\(inboxScope)-\(scenePhase)") {
            bedroom.configure(scope: inboxScope)
            guard let model = bedroom.workspace else { return }
            model.isActive = scenePhase == .active
            guard model.isActive else { return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeScreen(onConnect: {
                profile.onboardingComplete = true
                showWelcome = false
                deviceManager.startPolling()
            }, onDemo: {
                enterDemoMode()
            })
        }
        .task {
            deviceManager.selectSide(profile.defaultSide == .left ? .left : .right)
            scheduleManager.selectedSide = profile.defaultSide == .left ? .left : .right
            metricsManager.selectedSide = profile.defaultSide
            // Run setup until both onboarding steps are complete.
            if !profile.onboardingComplete && !isDemo {
                showWelcome = true
                return
            }

            // Demo mode — just fetch mock status, skip mDNS
            // Sensor demo stream starts automatically when Sensors tab is visited
            // via BedSensorScreen.onAppear -> connect() -> startDemoStream()
            if isDemo {
                await deviceManager.fetchStatus()
                deviceManager.startPolling()
                return
            }

            // Fetch once via startConnection, then hand off to polling. startPolling
            // detects the populated deviceStatus and skips its redundant first tick.
            await startConnection()
            deviceManager.startPolling()
        }
        .task(id: "\(scenePhase)-\(profile.defaultSide.rawValue)-\(healthSync.enabled)-\(healthSync.preferences.signature)-\(isConnected)-\(settingsManager.podIP)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if deviceManager.isConnected {
                    await healthSync.syncRecent(api: HealthSyncService.frozenClient(), podID: settingsManager.podID,
                                                side: profile.defaultSide, demo: isDemo)
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .task(id: "\(scenePhase)-\(backendIdentity)") {
            guard scenePhase == .active, !isDemo else { connectionPath.stop(); return }
            connectionPath.start(onPermission: { deviceManager.localNetworkAccessDenied = $0 }) { deviceManager.networkRouteChanged() }
            await UnifiedRuntime.refreshHealth()
        }
        .onDisappear { connectionPath.stop() }
        .onChange(of: scenePhase) {
            if !isDemo {
                if scenePhase == .active {
                    deviceManager.resumeConnection()
                    sensorStream.reconnect()
                } else if scenePhase == .background {
                    deviceManager.suspendConnection()
                    sensorStream.disconnect()
                }
            }
            if scenePhase == .background && healthSync.enabled && !isDemo {
                HealthSyncService.scheduleBackgroundSync()
            }
        }
        .onChange(of: deviceManager.isConnected) {
            if deviceManager.isConnected {
                podDiscovery.status = .idle
                // Auto-dismiss welcome screen when connection succeeds
                sensorStream.connect()
            }
        }
        .onChange(of: sensorStream.latestDeviceStatus?.ts) { _, _ in
            if !isDemo, let status = sensorStream.latestDeviceStatus, sensorStream.isCurrentPod {
                deviceManager.applyWebSocketStatus(status)
                deviceManager.isReceivingWebSocket = true
            }
        }
        .onChange(of: sensorStream.isConnected) { _, connected in
            if !connected {
                deviceManager.isReceivingWebSocket = false
            }
        }
    }

    // MARK: - Connection Flow

    private func startConnection() async {
        if OwnerConnection.endpoint != nil {
            await deviceManager.fetchStatus()
            return
        }
        // Probe the saved address alongside discovery so a DHCP change doesn't
        // cost a full request timeout before we can find the pod again.
        _ = await podDiscovery.autoConnect(settingsManager: settingsManager, deviceManager: deviceManager)
    }

    /// Back to the real backend and the setup flow, so the pod can be found again.
    private func leaveDemoMode() {
        APIBackend.current = .restoredLiveBackend
        let client = APIBackend.current.createClient()
        sensorStream.disconnect()
        deviceManager.switchBackend(client)
        settingsManager.switchBackend(client)
        scheduleManager.switchBackend(client)
        metricsManager.switchBackend(client)
        statusManager.switchBackend(client)
        profile.onboardingComplete = false
        showWelcome = true
    }

    private func enterDemoMode() {
        APIBackend.current = .demo
        let client = APIBackend.demo.createClient()
        deviceManager.switchBackend(client)
        settingsManager.switchBackend(client)
        scheduleManager.switchBackend(client)
        metricsManager.switchBackend(client)
        statusManager.switchBackend(client)
        sensorStream.disconnect()
        sensorStream.connect()
    }
}
