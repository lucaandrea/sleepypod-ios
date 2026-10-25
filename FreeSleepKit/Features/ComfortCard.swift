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
        SleepCard(title: "Comfort that learns", eyebrow: "FREE SLEEP AUTOPILOT") {
            HStack {
                Text("Local learning from your check-ins, bed presence and Pod vital estimates.").foregroundStyle(SleepTheme.secondary)
                Spacer()
                Text(status?.config.mode.capitalized ?? "Off").sleepText(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.primary.opacity(0.06), in: Capsule())
            }
            if let status {
                HStack(spacing: 24) {
                    let offset = celsius ? status.offsetF * 5 / 9 : status.offsetF
                    metric("Learned adjustment", "\(offset > 0 ? "+" : "")\(offset.formatted(.number.precision(.fractionLength(0...1))))°\(celsius ? "C" : "F")")
                    metric("Proposed target", status.decision.proposedF.map { "\(model.temperatureLabel($0))°\(celsius ? "C" : "F")" } ?? "—")
                }
                Text(status.decision.reason).sleepText(.body).foregroundStyle(SleepTheme.secondary)
                if let until = status.pausedUntil, until > Date().timeIntervalSince1970 * 1000 {
                    Text("Paused until \(Date(timeIntervalSince1970: until / 1000).formatted(date: .omitted, time: .shortened)).")
                        .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                }
                Picker("Comfort mode", selection: Binding(get: { config.mode }, set: { value in edit { $0.mode = value } })) {
                    Text("Off").tag("off")
                    Text("Preview · show proposals").tag("preview")
                    Text("Active · adjust temperatures").tag("active")
                }.disabled(busy)
                Stepper("Minimum: \(config.minimumF)°F", value: Binding(get: { config.minimumF }, set: { value in edit { $0.minimumF = value } }), in: 55...110).disabled(busy)
                Stepper("Maximum: \(config.maximumF)°F", value: Binding(get: { config.maximumF }, set: { value in edit { $0.maximumF = value } }), in: 55...110).disabled(busy)
                Toggle("Use sensor-aware Autopilot", isOn: Binding(get: { config.sensorAware ?? false }, set: { value in edit { $0.sensorAware = value; if !value { $0.followBedtime = false } } }))
                    .toggleStyle(SleepCheckboxStyle()).disabled(busy)
                if config.sensorAware == true {
                    Toggle("Follow earlier or later bed entry", isOn: Binding(get: { config.followBedtime ?? false }, set: { value in edit { $0.followBedtime = value } }))
                        .toggleStyle(SleepCheckboxStyle()).disabled(busy)
                    Text("Needs seven days of Pod estimates and two fresh five-minute windows. Unusual estimates hold extra adjustments. A heart-rate change never directly triggers cooling or movement.")
                        .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                    Text("Intermediate temperature phases can shift up to 30 minutes after stable bed entry. Power and wake time stay fixed. Temperature changes are limited to 1°F per 30 minutes and ±3°F from your routine.")
                        .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                    if let signals = status.signals {
                        Text("\(signals.baselineDays) baseline days · \(signals.reason)").sleepText(.small)
                        if let rate = signals.latestHeartRate, let baseline = signals.baselineHeartRate {
                            Text("Latest estimate \(Int(rate)) bpm · personal baseline \(Int(baseline)) bpm").sleepText(.caption)
                        }
                    }
                }
                Text("Snoring elevation is unavailable: no validated Pod snoring detector is connected. Bed presence is not sleep staging. Pod heart-rate estimates are limited to 30–90 bpm and cannot rule out abnormal readings.")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                Text("Learns at most 1°F from three new check-ins, up to ±3°F from your routine. Needs fresh presence. Manual controls pause it for six hours; your routine continues. Preview never changes the Pod.")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
                DisclosureGroup("Recent activity", isExpanded: $expanded) {
                    if status.history.isEmpty { Text("No comfort activity yet.").sleepText(.body) }
                    ForEach(Array(status.history.prefix(8).enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Date(timeIntervalSince1970: event.at / 1000).formatted(date: .abbreviated, time: .shortened))
                                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                            Text(event.message).sleepText(.body)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }
            } else if message == nil { ProgressView("Loading comfort settings…") }
            if let message { Text(message).sleepText(.body).foregroundStyle(SleepTheme.error) }
        }.task {
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
    }
    @ViewBuilder private var actions: some View {
        Button(busy ? "Saving…" : "Save comfort settings") { Task { await save(reset: false) } }
            .buttonStyle(SleepButtonStyle(kind: .primary)).disabled(busy || draft == nil || !config.valid)
        Button("Reset learning") { Task { await save(reset: true) } }
            .disabled(busy || status?.offsetF == 0 || draft != nil)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            Text(value).sleepText(.smallMetric)
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
