import SwiftUI
import UIKit

struct HomeRoomSummaryCard: View {
    @Environment(HomeRoomSession.self) private var session
    @Environment(SettingsManager.self) private var settings
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                if session.workspace?.isSyntheticExample == true { Eyebrow("SYNTHETIC EXAMPLE", color: Theme.amber) }
                Label(session.workspace?.status?.config.roomName ?? "Room sensors", systemImage: "house").font(.headline)
                Text("Home Assistant measurements").font(.caption).foregroundStyle(Theme.text2)
                if let model = session.workspace, let status = model.status {
                    let fresh = model.freshServerTime(at: context.date) != nil
                    Text(!fresh ? "Readings withheld · refresh required" : status.connected ? "MQTT subscription connected" : "MQTT not connected")
                        .font(.footnote).foregroundStyle(Theme.text2)
                    if status.observations.isEmpty { Text("No room sensors mapped.").foregroundStyle(Theme.text2) }
                    ForEach(status.observations) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(item.metric.title, systemImage: item.metric.symbol).font(.subheadline)
                            let value = model.value(item, at: context.date)
                            Text(formatted(value, metric: item.metric)).font(.title2.monospacedDigit())
                                .accessibilityIdentifier("room.value.\(item.metric.rawValue)")
                            if !compact {
                                Text(value == nil && item.status == .fresh ? "Waiting for a fresh update" : item.status.title).font(.caption).foregroundStyle(Theme.text2)
                                Text(item.entityId).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if let measured = item.measuredAt { Text("Measured \(Self.date(measured))").font(.caption).foregroundStyle(Theme.text2) }
                                if let expiry = item.expiresAt { Text("Expires \(Self.date(expiry))").font(.caption).foregroundStyle(Theme.text2) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else { Text(session.setupError ?? "Loading room sensors…").foregroundStyle(Theme.text2) }
                if let error = session.workspace?.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                Text("Separate from the Pod’s ambient sensors. Historical values never replace a missing live measurement.")
                    .font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if compact { NavigationLink("Room sensor setup and history") { HomeRoomScreen() }.accessibilityIdentifier("room.open") }
            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
        }
    }
    private func formatted(_ value: Double?, metric: HomeRoomMetric) -> String {
        var unit = metric.unit
        let converted: Double?
        if metric == .temperature && settings.temperatureFormat == .celsius { converted = value.map { ($0 - 32) * 5 / 9 }; unit = "°C" }
        else { converted = value }
        return (converted?.formatted(.number.precision(.fractionLength(0...1))) ?? "—") + " " + unit
    }
    static func date(_ milliseconds: Int64) -> String { Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(date: .abbreviated, time: .standard) }
}

struct HomeRoomScreen: View {
    @Environment(HomeRoomSession.self) private var session
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                NavigationLink { BedroomDevicesScreen() } label: {
                    Label("Bedroom devices", systemImage: "house").frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                }.buttonStyle(.plain).accessibilityIdentifier("room.bedroom")
                if APIBackend.current.isDemo && session.workspace?.isSyntheticExample != true { Text("DEMO · room input is unavailable. You can inspect a mapping draft without saving it.").font(.footnote).foregroundStyle(Theme.amber) }
                HomeRoomSummaryCard()
                if let model = session.workspace {
                    Button("Refresh room sensors") { Task { await model.refresh() } }.disabled(model.reading || model.saving).accessibilityIdentifier("room.refresh")
                    if model.base != nil {
                        NavigationLink { HomeRoomMappingScreen() } label: { Label("Sensor mapping and setup", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading).cardStyle() }
                            .accessibilityIdentifier("room.mapping")
                    }
                    publisher(model)
                    NavigationLink { HomeRoomHistoryScreen() } label: { Label("Room observation history", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, alignment: .leading).cardStyle() }
                        .accessibilityIdentifier("room.history")
                }
                NavigationLink { MQTTSettingsScreen() } label: { Label("MQTT connection", systemImage: "antenna.radiowaves.left.and.right") }
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("room.screen").background(Theme.background).navigationTitle("Room sensors").navigationBarTitleDisplayMode(.inline)
    }
    private func publisher(_ model: HomeRoomWorkspace) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                Text("Home Assistant publishers").font(.headline)
                Text("After every save, replace the previous publishers. Create one empty Home Assistant automation per sensor, choose Edit in YAML, and paste its document. JSON is valid YAML.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                Button(model.loadingPublisher ? "Generating…" : "Generate saved sensor publishers") { Task { await model.loadPublishers() } }
                    .disabled(model.loadingPublisher || model.pending != nil || model.status?.connected != true || model.status?.config.mappings.isEmpty != false || model.freshServerTime(at: context.date) == nil)
                    .accessibilityIdentifier("room.publishers")
                if let error = model.publisherError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                if let publishers = model.publisher, model.canUsePublisher(at: context.date) {
                    Text("Saved revision \(publishers.revision)").font(.caption)
                    ForEach(Array(publishers.automations.enumerated()), id: \.offset) { index, document in
                        DisclosureGroup("Publisher \(index + 1)") {
                            VStack(alignment: .leading, spacing: 10) {
                                Button("Copy publisher \(index + 1)", systemImage: "doc.on.doc") {
                                    if model.canUsePublisher(at: .now) { UIPasteboard.general.string = document }
                                }.accessibilityIdentifier("room.publisher.copy.\(index)")
                                ShareLink(item: document) { Label("Share publisher", systemImage: "square.and.arrow.up") }
                                    .accessibilityIdentifier("room.publisher.share.\(index)")
                                Text(document).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
        }
    }
}
