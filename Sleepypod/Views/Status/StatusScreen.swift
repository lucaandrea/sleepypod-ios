import SwiftUI

struct StatusScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(StatusManager.self) private var statusManager
    @Environment(ScheduleManager.self) private var scheduleManager
    @Environment(DeviceManager.self) private var deviceManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(PodDiscovery.self) private var podDiscovery
    @Environment(SensorStreamService.self) private var sensor

    @State private var activeRunOnceLeft: RunOnceSession?
    @State private var activeRunOnceRight: RunOnceSession?
    @State private var cancellingRunOnce: Set<Side> = []
    @State private var runOnceError: String?
    @State private var runOnceNotice: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Health circle
                HealthCircleView()

                if APIBackend.current != .freeSleep {
                    GroupedCard {
                        NavigationLink { SystemDashboardScreen() } label: {
                            SettingsRow("Overview", subtitle: "Tonight, maintenance and controller health", icon: "square.grid.2x2", iconColor: Theme.cool, chevron: true)
                        }.accessibilityIdentifier("system.dashboard")
                        Divider()
                        NavigationLink { SystemHealthScreen() } label: {
                            SettingsRow("Health", subtitle: "Data path, recovery and recorded checks", icon: "point.3.connected.trianglepath.dotted", iconColor: Theme.green, chevron: true)
                        }.accessibilityIdentifier("system.health")
                        Divider()
                        NavigationLink { SystemThermalScreen() } label: {
                            SettingsRow("Thermal", subtitle: "Temperature history and pump protection", icon: "thermometer.medium", iconColor: Theme.warm, chevron: true)
                        }.accessibilityIdentifier("system.thermal")
                        Divider()
                        NavigationLink { HardwareVibrationScreen() } label: {
                            SettingsRow("Hardware", subtitle: "Test cover vibration on one side", icon: "waveform", iconColor: Theme.purple, chevron: true)
                        }.accessibilityIdentifier("system.hardware")
                        Divider()
                        NavigationLink { SystemStorageScreen() } label: {
                            SettingsRow("Storage", subtitle: "Usage, raw history and eligible cleanup", icon: "internaldrive", iconColor: Theme.amber, chevron: true)
                        }.accessibilityIdentifier("system.storage")
                        Divider()
                        NavigationLink { SensorCalibrationScreen() } label: {
                            SettingsRow("Calibration", subtitle: "Sensor baselines, signals and validity", icon: "tuningfork", iconColor: Theme.cool, chevron: true)
                        }.accessibilityIdentifier("system.calibration")
                        Divider()
                        NavigationLink { SystemLogsScreen() } label: {
                            SettingsRow("Logs", subtitle: "Filter, follow and export service activity", icon: "doc.text", iconColor: Theme.text2, chevron: true)
                        }.accessibilityIdentifier("system.logs")
                        Divider()
                        NavigationLink { SystemSchedulerScreen() } label: {
                            SettingsRow("Scheduler", subtitle: "Seven nights and loaded jobs", icon: "calendar.badge.clock", iconColor: Theme.green, chevron: true)
                        }.accessibilityIdentifier("system.scheduler")
                        Divider()
                        NavigationLink { BedSensorScreen().navigationTitle("Sensors") } label: {
                            SettingsRow("Sensors", subtitle: "Presence, temperature, freezer and waveform inspection", icon: "waveform.path", iconColor: Theme.cool, chevron: true)
                        }.accessibilityIdentifier("system.sensors")
                        Divider()
                        NavigationLink { SystemDatabaseScreen() } label: {
                            SettingsRow("Databases", subtitle: "Inventory, rows and backups", icon: "externaldrive", iconColor: Theme.cool, chevron: true)
                        }.accessibilityIdentifier("system.databases")
                    }
                }

                if !statusManager.statusIsFresh() {
                    Text(statusManager.serverStatus == nil ? "Service status is unavailable." : "Service status may be stale. Last successful readings are shown below.")
                        .font(.footnote).foregroundStyle(Theme.amber)
                }
                // Service categories + hardware details
                let cats = statusManager.categories(schedules: scheduleManager.schedules)
                if cats.isEmpty && statusManager.isLoading {
                    LoadingView(message: "Checking services…")
                } else {
                    ForEach(cats) { category in
                        ServiceCategoryView(category: category) { service in
                            Task { await statusManager.retryService(service) }
                        }

                        // Insert hardware-related cards after the Hardware category
                        if category.name == "Hardware" {
                            processingCard
                            networkDiscoveryCard

                            if let runOnceError { Text(runOnceError).foregroundStyle(Theme.amber) }
                            if let runOnceNotice { Text(runOnceNotice).foregroundStyle(Theme.text2) }

                            // Active run-once curves
                            if let session = activeRunOnceLeft {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Left")
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(Theme.accent)
                                        .padding(.leading, 4)
                                    RunOnceActiveBanner(session: session, onCancel: {
                                        Task { await cancelRunOnce(.left) }
                                    }).disabled(cancellingRunOnce.contains(.left))
                                }
                            }
                            if let session = activeRunOnceRight {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Right")
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(Color(hex: "40e0d0"))
                                        .padding(.leading, 4)
                                    RunOnceActiveBanner(session: session, onCancel: {
                                        Task { await cancelRunOnce(.right) }
                                    }).disabled(cancellingRunOnce.contains(.right))
                                }
                            }
                        }
                    }
                }

                // Systemd services
                if !statusManager.logSources.isEmpty {
                    servicesCard
                }

                // Last updated
                if let lastUpdated = statusManager.lastUpdated {
                    Text("Last updated: \(lastUpdated, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(Theme.background)
        .onDisappear { statusManager.stopPolling() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { statusManager.stopPolling(); return }
            statusManager.startPolling()
            await scheduleManager.fetchSchedules()
            let api = APIBackend.current.createClient()
            activeRunOnceLeft = try? await api.getActiveRunOnce(side: .left)
            activeRunOnceRight = try? await api.getActiveRunOnce(side: .right)
        }
    }

    // Core cancellation resumes the recurring schedule; it must not send a separate power-off.
    private func cancelRunOnce(_ side: Side) async {
        guard !cancellingRunOnce.contains(side) else { return }
        cancellingRunOnce.insert(side); runOnceError = nil; runOnceNotice = nil
        defer { cancellingRunOnce.remove(side) }
        do {
            try await APIBackend.current.createClient().cancelRunOnce(side: side)
            withAnimation {
                if side == .left { activeRunOnceLeft = nil } else { activeRunOnceRight = nil }
            }
            runOnceNotice = "Run once cancelled. The recurring schedule resumes."
            await deviceManager.fetchStatus()
        } catch { runOnceError = error.localizedDescription }
    }

    // MARK: - Processing

    @State private var isMLExpanded = false

    private var processingCard: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.light()
                withAnimation(.easeInOut(duration: 0.2)) { isMLExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "brain")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.purple)
                        .frame(width: 32, height: 32)
                        .background(Theme.purple.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("On-Device Intelligence")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Theme.text1)
                        Text("rule-based · on this iPhone")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(Theme.healthy)
                        Text("3/3")
                            .font(.caption.weight(.medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.active)
                    .clipShape(Capsule())

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                        .rotationEffect(.degrees(isMLExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isMLExpanded {
                Divider().background(Theme.cardBorder).padding(.vertical, 8)

                VStack(spacing: 6) {
                    modelRow(
                        name: "Sleep Stage Classifier",
                        type: "Rule-based",
                        status: "Active",
                        icon: "moon.zzz.fill",
                        color: Theme.purple
                    )
                    modelRow(
                        name: "Outlier Filter",
                        type: "Sleep-context limits · rolling median",
                        status: "Active",
                        icon: "line.3.crossed.swirl.circle.fill",
                        color: Theme.accent
                    )
                    modelRow(
                        name: "HRV Trend Analysis",
                        type: "EMA baseline comparison",
                        status: "Active",
                        icon: "chart.xyaxis.line",
                        color: Theme.healthy
                    )

                    Divider().background(Theme.cardBorder).padding(.vertical, 4)

                    // Future models
                    modelRow(
                        name: "Sleep Stage CNN",
                        type: "Core ML · Requires training data",
                        status: "Not trained",
                        icon: "brain.head.profile.fill",
                        color: Theme.textMuted
                    )
                    modelRow(
                        name: "Anomaly Detection",
                        type: "Core ML · Requires baseline",
                        status: "Not trained",
                        icon: "exclamationmark.bubble.fill",
                        color: Theme.textMuted
                    )
                }
            }
        }
        .padding(16)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func modelRow(name: String, type: String, status: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.caption)
                    .foregroundColor(Theme.text1)
                Text(type)
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
            }
            Spacer()
            Text(status)
                .font(.caption2)
                .foregroundColor(color == Theme.textMuted ? Theme.textMuted : Theme.healthy)
        }
    }

    // MARK: - Services

    @State private var servicesExpanded = false

    private var servicesCard: some View {
        let sources = statusManager.logSources
        let activeCount = sources.filter(\.active).count
        let allHealthy = activeCount == sources.count

        return VStack(spacing: 0) {
            // Header — matches ServiceCategoryView pattern
            Button {
                Haptics.light()
                withAnimation(.easeInOut(duration: 0.2)) {
                    servicesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.cool)
                        .frame(width: 32, height: 32)
                        .background(Theme.cool.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Services")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Theme.text1)
                        Text("Systemd service units")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: allHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(allHealthy ? Theme.healthy : Theme.amber)
                        Text("\(activeCount)/\(sources.count)")
                            .font(.caption.weight(.medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.active)
                    .clipShape(Capsule())

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.textMuted)
                        .rotationEffect(.degrees(servicesExpanded ? 90 : 0))
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            // Expanded — checkmark rows
            if servicesExpanded {
                Divider().background(Theme.cardBorder)

                VStack(spacing: 0) {
                    ForEach(sources) { source in
                        HStack(spacing: 10) {
                            Image(systemName: source.active ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(source.active ? Theme.healthy : Theme.error)
                            Text(source.name)
                                .font(.caption)
                                .foregroundColor(Theme.text1)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Network Discovery

    @State private var isDiscoveryExpanded = false

    private var networkDiscoveryCard: some View {
        VStack(spacing: 0) {
            // Header — matches ServiceCategoryView style
            Button {
                Haptics.light()
                withAnimation(.easeInOut(duration: 0.2)) {
                    isDiscoveryExpanded.toggle()
                }
                // Only scan when disconnected — don't disrupt active connection
                if isDiscoveryExpanded && !deviceManager.isConnected && !podDiscovery.isSearching {
                    podDiscovery.startBrowsing()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.accent)
                        .frame(width: 32, height: 32)
                        .background(Theme.accent.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Network Discovery")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Theme.text1)
                        Text("mDNS auto-discovery")
                            .font(.caption)
                            .foregroundColor(Theme.textSecondary)
                    }

                    Spacer()

                    // Status badge — matches ServiceCategoryView pattern
                    HStack(spacing: 4) {
                        Image(systemName: deviceManager.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(deviceManager.isConnected ? Theme.healthy : Theme.amber)
                        Text(deviceManager.isConnected ? "1/1" : "0/1")
                            .font(.caption.weight(.medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.active)
                    .clipShape(Capsule())

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                        .rotationEffect(.degrees(isDiscoveryExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isDiscoveryExpanded {
                Divider()
                    .background(Theme.cardBorder)
                    .padding(.vertical, 8)

                VStack(spacing: 8) {
                    // Connected pod info
                    if deviceManager.isConnected {
                        HStack(spacing: 10) {
                            Image("LogoMark")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(podDiscovery.connectedPodName ?? podDiscovery.discoveredPods.first?.name ?? settingsManager.podIP)
                                    .font(.subheadline)
                                    .foregroundColor(Theme.text1)
                                Text(settingsManager.podIP)
                                    .font(.caption)
                                    .foregroundColor(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.healthy)
                        }
                        .padding(.vertical, 4)
                    }

                    // Discovered pods from scan
                    if podDiscovery.isSearching {
                        HStack(spacing: 8) {
                            ProgressView().tint(Theme.accent).scaleEffect(0.7)
                            Text("Scanning network…")
                                .font(.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                        .padding(.vertical, 4)
                    } else if !podDiscovery.discoveredPods.isEmpty {
                        ForEach(podDiscovery.discoveredPods) { pod in
                            HStack(spacing: 10) {
                                Image("LogoMark")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                                Text(pod.name)
                                    .font(.caption)
                                    .foregroundColor(Theme.text1)
                                Spacer()
                                Text("Port \(pod.port)")
                                    .font(.caption2)
                                    .foregroundColor(Theme.textMuted)
                            }
                            .padding(.vertical, 2)
                        }
                    } else if !deviceManager.isConnected {
                        Text("No sleepypod found on network")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

}
