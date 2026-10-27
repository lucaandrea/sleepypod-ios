import SwiftUI

public enum PodFeature: String, Sendable, CaseIterable {
    case comfort, journal, history, reports, models, healthHistory, healthSync, home, routines, alarms, coach, preferences, services, base

    public var title: String {
        switch self {
        case .comfort: "Personal comfort"
        case .journal: "Morning check-in"
        case .history: "Recorded episodes"
        case .reports: "Personal reports"
        case .models: "Models"
        case .healthHistory: "Health history"
        case .healthSync: "Pod Health export"
        case .home: "Home & Shortcuts"
        case .routines: "Routine editor"
        case .alarms: "Next alarm"
        case .coach: "Sleep coach"
        case .preferences: "Pod preferences"
        case .services: "Pod services"
        case .base: "Bed position"
        }
    }

    var needsPod: Bool {
        ![.reports, .models, .healthHistory, .home].contains(self)
    }
}

/// Hosts a detail editor inside Sleepypod's existing navigation; owns no app shell.
public struct PodFeatureScreen: View {
    private let feature: PodFeature
    private let side: String
    private let homeContent: AnyView?
    private let nativeActions: NativePodActionBridge
    @State private var model = AppModel()
    @State private var health = HealthSyncService.shared
    @State private var availability: String?
    @State private var checking = true
    @Environment(\.scenePhase) private var phase
    @AppStorage("podURL") private var address = ""
    @AppStorage("podNativeAPIPrefix") private var prefix = ""
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    private var needsLegacyPod: Bool { feature.needsPod && !(feature == .coach && (AppMode.isCore || AppMode.isDemo)) }

    public init(_ feature: PodFeature, side: String = "left", homeContent: AnyView? = nil, nativeActions: NativePodActionBridge = .unavailable) {
        self.feature = feature
        self.side = side
        self.homeContent = homeContent
        self.nativeActions = nativeActions
    }

    public var body: some View {
        Group {
            if checking && needsLegacyPod {
                ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let availability, needsLegacyPod {
                ContentUnavailableView(feature.title, systemImage: "network.slash", description: Text(availability))
            } else { content }
        }
        .background(Theme.background).foregroundStyle(Theme.text1).tint(Theme.text1)
        .navigationTitle(feature.title).navigationBarTitleDisplayMode(.inline)
        .environment(model).environment(health)
        .task(id: "\(address)|\(prefix)|\(side)|\(phase)|\(ownerRevision)") {
            guard phase == .active else { return }
            model.side = BedSide(rawValue: side) ?? .left
            model.connectionChanged()
            checking = true
            availability = await compatibilityMessage()
            checking = false
            guard availability == nil, needsLegacyPod else { return }
            while !Task.isCancelled {
                await model.refresh(includeAnalytics: feature == .history)
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch feature {
        case .comfort: FeaturePage(title: feature.title) { SidePicker(); ComfortCard().id(model.side) }
        case .journal: FeaturePage(title: feature.title) { SidePicker(); JournalCard().id(model.side) }
        case .history: RecordedEpisodesScreen()
        case .reports: PersonalReportsScreen(nativeActions: nativeActions)
        case .models: ModelConnectionScreen()
        case .healthHistory: ImportedHealthScreen()
        case .healthSync: FeaturePage(title: feature.title) { HealthConnectionCard() }
        case .home: HomeShortcutsScreen(homeContent: homeContent)
        case .routines: RoutinesView()
        case .alarms: FeaturePage(title: feature.title) { SidePicker(); AlarmCard(side: model.side).id(model.side) }
        case .coach:
            if AppMode.isCore || AppMode.isDemo { PersonalReportsScreen(coach: true, nativeActions: nativeActions) }
            else { CoachView() }
        case .preferences: DevicePreferencesView()
        case .services: SystemHealthView()
        case .base: LegacyBaseScreen()
        }
    }

    // Core advertises this optional contract. Never mount an editor against missing routes.
    private func compatibilityMessage() async -> String? {
        guard !model.demo, needsLegacyPod, prefix == "native/v1" else { return nil }
        do {
            let client = try PodClient(address: address, token: TokenStore.read(for: address), apiPrefix: "v1")
            let capabilities: NativeCapabilities = try await client.get("capabilities")
            return capabilities.supportsNative ? nil : "This controller does not provide this feature yet. Temperature, schedules and sleep remain available in the main tabs."
        } catch { return "Could not check this controller’s features. Check your Pod connection in Settings." }
    }
}

struct NativeCapabilities: Decodable, Sendable {
    struct Endpoints: Decodable, Sendable { let nativeCompatibility: String? }
    struct Feature: Decodable, Sendable { let implemented: Bool; let runtime: String }
    struct Features: Decodable, Sendable { let nativeCompatibility: Feature }
    let apiVersion: Int
    let endpoints: Endpoints
    let features: Features
    var supportsNative: Bool {
        apiVersion == 1 && endpoints.nativeCompatibility == "/api/native/v1"
            && features.nativeCompatibility.implemented && features.nativeCompatibility.runtime == "ready"
    }
}

struct ModelConnectionScreen: View {
    @State private var workspace = IntelligenceWorkspace.shared
    var body: some View {
        FeaturePage(title: "Models") {
            ModelSettingsCard(workspace: workspace)
            if let message = workspace.message { Text(message).font(.footnote) }
        }.task { workspace.restore() }
    }
}

struct ImportedHealthScreen: View {
    @State private var workspace = IntelligenceWorkspace.shared
    var body: some View {
        FeaturePage(title: "Health history") {
            HealthHistoryCard(workspace: workspace)
            if let message = workspace.message { Text(message).font(.footnote) }
        }.task { workspace.restore() }
    }
}

struct RecordedEpisodesScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        FeaturePage(title: "Recorded episodes") {
            SidePicker()
            FeatureSegments(title: "History range", options: [7, 30, 90], selection: $model.days) { "\($0) days" }
            if let error = model.analyticsError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            EpisodeBrowser(episodes: model.analytics?.episodes ?? model.analytics?.nights ?? [], timeZone: model.analytics?.timeZone ?? "UTC")
                .id("\(model.side.rawValue):\(model.days)")
            if let analytics = model.analytics {
                DataCoverageCard(report: analytics.quality?.coverage, timeZone: analytics.timeZone)
                FeatureSection(title: "Bed presence") {
                    PresenceChart(nights: analytics.nights)
                    Text("Bed presence does not establish sleep stages or sleep quality.").font(.caption).foregroundStyle(Theme.text2)
                }
            }
        }.refreshable { await model.refresh() }
    }
}

struct HomeShortcutsScreen: View {
    let homeContent: AnyView?
    var body: some View {
        FeaturePage(title: "Home & Shortcuts") {
            SleepShortcutsCard()
            if let homeContent { homeContent }
            HomeConnectionCard()
        }
    }
}
