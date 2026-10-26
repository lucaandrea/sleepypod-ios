import SwiftUI

struct AutomationHistoryScreen: View {
    @Environment(SettingsManager.self) private var settings
    let client: any AutomationClient
    @State private var activity: AutomationActivity?
    @State private var days = 3
    @State private var filter = AutomationActivityFilter.all
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if DebugRoute.automationReplayFixture { Text("Synthetic activity fixture · no bed commands").font(.footnote).foregroundStyle(Theme.amber) }
                Picker("Events", selection: $filter) { ForEach(AutomationActivityFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).accessibilityIdentifier("automation.activityFilter")
                Text("Nights begin at 6pm · \(settings.timeZone)").font(.footnote).foregroundStyle(Theme.text2)
                if let error { Text(error).foregroundStyle(Theme.amber) }
                if let activity {
                    ForEach(activity.nights) { night in
                        GroupedCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(AutomationDates.label(night.start, timeZone: settings.timeZone, includeDate: true)).font(.headline)
                                let entries = night.entries.filter(filter.matches)
                                if entries.isEmpty { Text("No matching events.").foregroundStyle(Theme.text2) }
                                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.ruleName).font(.subheadline.weight(.semibold))
                                        Text("\(AutomationDates.label(entry.start, timeZone: settings.timeZone))\(entry.end > entry.start ? " – " + AutomationDates.label(entry.end, timeZone: settings.timeZone) : "") · \(entry.code.replacingOccurrences(of: "-", with: " ")) · \(entry.count) evaluation\(entry.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.text2)
                                        if let temp = entry.temp { Text("\(temp.formatted())°F · \(entry.sides.map(\.rawValue).joined(separator: ", "))").font(.footnote) }
                                        Text(entry.outcome == "dry_run" ? "Would fire · no command" : entry.outcome.replacingOccurrences(of: "_", with: " ")).font(.caption)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                    }
                    if !activity.holds.isEmpty {
                        Text("Manual holds").font(.headline)
                        ForEach(Array(activity.holds.enumerated()), id: \.offset) { _, hold in
                            Text("\(settings.sideName(for: hold.side)) · \(hold.temperature.formatted())°F · \(AutomationDates.label(hold.startedAt, timeZone: settings.timeZone, includeDate: true)) – \(AutomationDates.label(hold.expiresAt, timeZone: settings.timeZone))").font(.footnote)
                        }
                    }
                }
                if loading { ProgressView("Loading activity…") }
                Button("Load older nights") { days = min(30, days + 3) }.disabled(loading || days >= 30)
                Button("Reload activity") { Task { await load() } }.disabled(loading)
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
            .task(id: "\(days)-\(settings.timeZone)") { await load() }
    }
    private func load() async {
        loading = true; error = nil
        do {
            let response = try await client.activity(nightStarts: AutomationActivity.nightStarts(count: days, timeZone: TimeZone(identifier: settings.timeZone) ?? .current))
            guard !Task.isCancelled else { return }; activity = response
        } catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription }
        loading = false
    }
}

struct AutomationZoneReplayScreen: View {
    @Environment(SettingsManager.self) private var settings
    let client: any AutomationClient
    let side: Side
    let night: Int?
    @State private var replay: AutomationZoneReplay?
    @State private var frameIndex = 0.0
    @State private var error: String?
    @State private var loading = true
    @State private var playing = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Recorded pressure zones · \(settings.sideName(for: side))").font(.headline)
                if DebugRoute.automationReplayFixture { Text("Synthetic pressure-zone fixture · not your bed data").font(.footnote).foregroundStyle(Theme.amber) }
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(Theme.amber) }
                if let replay, replay.ok, !replay.frames.isEmpty {
                    let frame = replay.frames[min(Int(frameIndex), replay.frames.count - 1)]
                    Text(AutomationDates.label(frame.tMs, timeZone: settings.timeZone, includeDate: true)).font(.footnote.monospacedDigit())
                    AutomationZoneBars(values: frame.zones, scale: replay.scale, peak: frame.peakZone.flatMap { value in value.isFinite && value >= 0 && value < Double(frame.zones.count) ? Int(value) : nil } ?? frame.zones.filter(\.isFinite).max().flatMap { $0 > 0 ? frame.zones.firstIndex(of: $0) : nil })
                    Button(playing ? "Pause replay" : "Play replay", systemImage: playing ? "pause.fill" : "play.fill") { playing.toggle() }
                        .disabled(replay.frames.count < 2).accessibilityIdentifier("automation.playZones")
                    Text("Frame \(Int(frameIndex) + 1) of \(replay.frames.count)").font(.caption).accessibilityIdentifier("automation.zoneFrame")
                    Slider(value: $frameIndex, in: 0...Double(max(1, replay.frames.count - 1)), step: 1).disabled(replay.frames.count < 2).accessibilityLabel("Replay frame")
                    Text("Colors use one fixed scale across this night. Values are sensor loads, not calibrated body pressure. Devices without spatial readings have no zone replay.").font(.footnote).foregroundStyle(Theme.text2)
                } else if !loading { Text("No spatial zone recordings for this night.").foregroundStyle(Theme.text2) }
                Button("Reload zones") { Task { await load() } }.disabled(loading)
            }.frame(maxWidth: 680, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Pressure zones").navigationBarTitleDisplayMode(.inline).task { await load() }
            .task(id: playing) {
                while playing, !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    guard let frames = replay?.frames, !frames.isEmpty else { playing = false; return }
                    frameIndex = Double((Int(frameIndex) + 1) % frames.count)
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { playing = false } }
            .onDisappear { playing = false }
    }
    private func zoneLabel(_ index: Int, count: Int) -> String { count == 3 ? ["Head", "Torso", "Legs"][index] : "Zone \(index + 1)" }
    private func load() async {
        playing = false; loading = true; error = nil
        do { replay = try await client.zones(side: side, night: night); frameIndex = 0 }
        catch { replay = nil; self.error = error.localizedDescription }
        loading = false
    }
}
