import SwiftUI

struct ComfortCard: View {
    @Environment(AppModel.self) private var model
    @State private var status: ComfortStatus?
    @State private var draft: ComfortConfig?
    @State private var message: String?
    @State private var busy = false
    @State private var expanded = false
    private var config: ComfortConfig { draft ?? status?.config ?? .initial }
    private var celsius: Bool { model.settings?.temperatureFormat == "celsius" }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let status {
                GroupedSection("MODE") {
                    GroupedCard {
                        SettingsRow("Personal comfort", icon: "sparkles") {
                            Picker("Comfort mode", selection: Binding(get: { config.mode }, set: { value in edit { $0.mode = value } })) {
                                Text("Off").tag("off")
                                Text("Preview").tag("preview")
                                Text("Active").tag("active")
                            }.labelsHidden().disabled(busy)
                        }
                    }
                    Text("Preview shows proposals. Active adjusts temperature within your limits; your routine remains the starting point.")
                        .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow("CURRENT DECISION")
                    HStack(spacing: 24) {
                        let offset = celsius ? status.offsetF * 5 / 9 : status.offsetF
                        metric("Adjustment", "\(offset > 0 ? "+" : "")\(offset.formatted(.number.precision(.fractionLength(0...1))))°\(celsius ? "C" : "F")")
                        metric("Proposed target", status.decision.proposedF.map { "\(model.temperatureLabel($0))°\(celsius ? "C" : "F")" } ?? "—")
                    }
                    Text(status.decision.reason).font(.subheadline).foregroundStyle(Theme.text2)
                    if let until = status.pausedUntil, until > Date().timeIntervalSince1970 * 1000 {
                        Text("Paused until \(Date(timeIntervalSince1970: until / 1000).formatted(date: .omitted, time: .shortened)).")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                }.cardStyle()
                GroupedSection("LIMITS") {
                    GroupedCard {
                        Stepper("Minimum: \(config.minimumF)°F", value: Binding(get: { config.minimumF }, set: { value in edit { $0.minimumF = value } }), in: 55...110).padding(16)
                        Stepper("Maximum: \(config.maximumF)°F", value: Binding(get: { config.maximumF }, set: { value in edit { $0.maximumF = value } }), in: 55...110).padding(16)
                        Toggle("Use sensor-aware Autopilot", isOn: Binding(get: { config.sensorAware ?? false }, set: { value in edit { $0.sensorAware = value; if !value { $0.followBedtime = false } } }))
                            .tint(Theme.green).padding(16)
                        if config.sensorAware == true {
                            Toggle("Follow bed entry", isOn: Binding(get: { config.followBedtime ?? false }, set: { value in edit { $0.followBedtime = value } }))
                                .tint(Theme.green).padding(16)
                        }
                    }.disabled(busy)
                    Text("Learns at most 1°F from three new check-ins, up to ±3°F from your routine. Manual controls pause adjustments for six hours.")
                        .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16)
                }
                if config.sensorAware == true {
                    GroupedSection("SENSORS") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let signals = status.signals {
                                Text("\(signals.baselineDays) baseline days · \(signals.reason)")
                                if let rate = signals.latestHeartRate, let baseline = signals.baselineHeartRate {
                                    Text("Latest estimate \(Int(rate)) bpm · baseline \(Int(baseline)) bpm")
                                }
                            }
                            Text("Needs seven baseline days and two fresh five-minute windows. Temperature phases can shift up to 30 minutes; power and wake time stay fixed. Extra changes are limited to 1°F per 30 minutes and ±3°F from your routine.")
                        }.font(.footnote).foregroundStyle(Theme.text2).cardStyle()
                    }
                }
                actions
                GroupedSection("ACTIVITY") {
                    GroupedCard {
                        DisclosureGroup("Recent activity", isExpanded: $expanded) {
                            if status.history.isEmpty { Text("No comfort activity yet.").font(.subheadline) }
                            ForEach(Array(status.history.prefix(8).enumerated()), id: \.offset) { _, event in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(Date(timeIntervalSince1970: event.at / 1000).formatted(date: .abbreviated, time: .shortened))
                                        .font(.mono(11, relativeTo: .caption)).foregroundStyle(Theme.text2)
                                    Text(event.message).font(.subheadline)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                            }
                        }.padding(16)
                    }
                    Text("Snoring elevation is unavailable. Bed presence is not sleep staging. Pod heart-rate estimates are limited to 30–90 bpm and cannot rule out abnormal readings; they never directly trigger cooling or movement.")
                        .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16)
                }
            } else if message == nil { ProgressView("Loading comfort settings…") }
            if let message { Text(message).font(.footnote).foregroundStyle(Theme.amber) }
        }.task {
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
    }
    @ViewBuilder private var actions: some View {
        Button(busy ? "Saving…" : "Save comfort settings") { Task { await save(reset: false) } }
            .buttonStyle(PrimaryButtonStyle()).disabled(busy || draft == nil || !config.valid)
        Button("Reset learning") { Task { await save(reset: true) } }
            .disabled(busy || status?.offsetF == 0 || draft != nil)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            Text(value).font(.title2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func edit(_ change: (inout ComfortConfig) -> Void) {
        var updated = config; change(&updated); draft = updated
    }
    private func load() async {
        if model.demo { if status == nil { status = .demo }; return }
        do {
            let value: ComfortStatus = try await PodClient.configured().get("comfort", query: [URLQueryItem(name: "side", value: model.side.rawValue)])
            guard !Task.isCancelled else { return }
            status = value; message = nil
        } catch { if !Task.isCancelled { message = "Comfort settings are unavailable. Check your Pod connection." } }
    }
    private func save(reset: Bool) async {
        guard config.valid else { return }
        busy = true; message = nil
        defer { busy = false }
        let selected = model.side.rawValue
        let update = config
        do {
            if model.demo {
                status?.config = update
                if reset { status?.offsetF = 0 }
                status?.decision.reason = update.mode == "off" ? "Adaptive comfort is off." : "Demo preview. No temperatures will change."
                status?.history.insert(.init(at: Date().timeIntervalSince1970 * 1000, message: "Adaptive comfort set to \(update.mode).", targetF: nil), at: 0)
            } else {
                struct Request: Encodable, Sendable { var side: String; var config: ComfortConfig; var reset: Bool }
                try await PodClient.configured().post("comfort", body: Request(side: selected, config: update, reset: reset))
                await load()
            }
            draft = nil
        } catch { message = error.localizedDescription }
    }
}
