import SwiftUI

struct AutomationHistoryScreen: View {
    @Environment(SettingsManager.self) private var settings
    let client: any AutomationClient
    @State private var activity: AutomationActivity?
    @State private var days = 3
    @State private var filter = "All"
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Events", selection: $filter) { ForEach(["All", "Would fire", "Fired", "Skipped", "Missing", "Errors"], id: \.self) { Text($0) } }.pickerStyle(.menu)
                Text("Nights begin at 6pm · \(settings.timeZone)").font(.footnote).foregroundStyle(Theme.text2)
                if let error { Text(error).foregroundStyle(Theme.amber) }
                if let activity {
                    ForEach(activity.nights) { night in
                        GroupedCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(AutomationDates.label(night.start, timeZone: settings.timeZone, includeDate: true)).font(.headline)
                                let entries = night.entries.filter(matches)
                                if entries.isEmpty { Text("No matching events.").foregroundStyle(Theme.text2) }
                                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.ruleName).font(.subheadline.weight(.semibold))
                                        Text("\(AutomationDates.label(entry.start, timeZone: settings.timeZone)) · \(entry.code.replacingOccurrences(of: "-", with: " ")) · \(entry.count) evaluation\(entry.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.text2)
                                        if let temp = entry.temp { Text("\(temp.formatted())°F · \(entry.sides.map(\.rawValue).joined(separator: ", "))").font(.footnote) }
                                        Text(entry.outcome == "dry_run" ? "Would fire · no command" : entry.outcome.replacingOccurrences(of: "_", with: " ")).font(.caption)
                                    }
                                }
                            }.padding(16)
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
    private func matches(_ entry: AutomationActivity.Entry) -> Bool {
        switch filter {
        case "Would fire": entry.outcome == "dry_run"
        case "Fired": entry.outcome == "fired" || entry.outcome == "clamped"
        case "Skipped": entry.outcome == "skipped"
        case "Missing": entry.code == "signal-unavailable" || entry.code.contains("unknown") || entry.code.contains("missing")
        case "Errors": entry.outcome == "error"
        default: true
        }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Recorded pressure zones · \(settings.sideName(for: side))").font(.headline)
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(Theme.amber) }
                if let replay, replay.ok, !replay.frames.isEmpty {
                    let frame = replay.frames[min(Int(frameIndex), replay.frames.count - 1)]
                    Text(AutomationDates.label(frame.tMs, timeZone: settings.timeZone, includeDate: true)).font(.footnote.monospacedDigit())
                    ForEach(frame.zones.indices, id: \.self) { index in
                        let value = frame.zones[index]
                        let maximum = max(1, frame.zones.filter(\.isFinite).max() ?? 1)
                        let intensity = value.isFinite ? min(1, max(0, value / maximum)) : 0
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(zoneLabel(index, count: frame.zones.count)): \(value.isFinite ? value.formatted(.number.precision(.fractionLength(0...2))) : "Missing")")
                            RoundedRectangle(cornerRadius: 16).fill(Theme.green.opacity(0.08 + intensity * 0.72)).frame(height: 52)
                        }.accessibilityElement(children: .combine)
                    }
                    Slider(value: $frameIndex, in: 0...Double(max(1, replay.frames.count - 1)), step: 1).disabled(replay.frames.count < 2).accessibilityLabel("Replay frame")
                    Text("Color compares zones within this frame. Values are sensor loads, not calibrated body pressure. Devices without spatial readings have no zone replay.").font(.footnote).foregroundStyle(Theme.text2)
                } else if !loading { Text("No spatial zone recordings for this night.").foregroundStyle(Theme.text2) }
                Button("Reload zones") { Task { await load() } }.disabled(loading)
            }.frame(maxWidth: 680, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Pressure zones").navigationBarTitleDisplayMode(.inline).task { await load() }
    }
    private func zoneLabel(_ index: Int, count: Int) -> String { count == 3 ? ["Head", "Torso", "Legs"][index] : "Zone \(index + 1)" }
    private func load() async {
        loading = true; error = nil
        do { replay = try await client.zones(side: side, night: night); frameIndex = 0 }
        catch { replay = nil; self.error = error.localizedDescription }
        loading = false
    }
}
