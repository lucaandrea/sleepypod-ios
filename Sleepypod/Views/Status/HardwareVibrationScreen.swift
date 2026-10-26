import SwiftUI

struct HardwareVibrationScreen: View {
    @Environment(DeviceManager.self) private var device
    @Environment(SettingsManager.self) private var settings
    @State private var model: HardwareVibrationWorkspace
    @State private var side: Side = .left
    @State private var preset: HardwareVibrationPreset = .quick
    @State private var customDuration = 10
    private var duration: Int { preset.duration ?? customDuration }
    init(client: (any HardwareVibrationClient)? = nil) {
        let selected: any HardwareVibrationClient
        if let client { selected = client }
        else if APIBackend.current.isDemo { selected = DemoHardwareVibrationClient() }
        else if APIBackend.current == .freeSleep { selected = LegacyHardwareVibrationClient(api: APIBackend.current.createClient()) }
        else { selected = CoreHardwareVibrationClient() }
        _model = State(initialValue: .init(client: selected))
    }
    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(alignment: .leading, spacing: 16) {
                    if APIBackend.current.isDemo { Text("DEMO · simulated vibration requests").font(.footnote).foregroundStyle(Theme.amber) }
                    Text("Test the cover on one side. The test changes the current alarm on that side; scheduled future alarms stay in place.").font(.footnote).foregroundStyle(Theme.text2)
                    GroupedCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Test vibration").font(.headline)
                            Picker("Side", selection: $side) {
                                ForEach(Side.allCases) { side in Text(settings.sideName(for: side)).tag(side) }
                            }.disabled(model.busy || model.active(at: timeline.date) != nil || model.uncertainSide != nil).accessibilityIdentifier("vibration.side")
                            Picker("Duration preset", selection: $preset) {
                                ForEach(HardwareVibrationPreset.allCases) { value in Text(value.title).tag(value) }
                            }.disabled(model.busy).accessibilityIdentifier("vibration.preset")
                            if preset == .custom {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Duration: \(customDuration) seconds").monospacedDigit()
                                    Stepper("Custom duration", value: $customDuration, in: 1...60)
                                        .labelsHidden().accessibilityLabel("Custom duration")
                                        .disabled(model.busy).accessibilityIdentifier("vibration.duration")
                                }
                            }
                            Text("\(preset.summary) · \(duration) seconds").font(.subheadline)
                            preview(at: timeline.date)
                            Button("Play on \(settings.sideName(for: side))") { Task { await model.play(side: side, duration: duration) } }
                                .disabled(model.busy || model.uncertainSide != nil).accessibilityIdentifier("vibration.play")
                            let stoppingSide = model.uncertainSide ?? model.active(at: timeline.date)?.side ?? side
                            Button("Stop \(settings.sideName(for: stoppingSide))", role: .destructive) { Task { await model.stop(selectedSide: side) } }
                                .disabled(model.busy).accessibilityIdentifier("vibration.stop")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    if model.busy { ProgressView("Sending request…") }
                    if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("vibration.notice") }
                    if let error = model.error { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("vibration.error") }
                    Text("You can leave this screen while the test runs. Use Stop to end it early.").font(.footnote).foregroundStyle(Theme.text2)
                }.padding(16)
            }
        }.accessibilityIdentifier("vibration.content").background(Theme.background).navigationTitle("Hardware").navigationBarTitleDisplayMode(.inline)
            .onAppear { if model.playing == nil && model.uncertainSide == nil { side = device.selectedSide.sides.first ?? .left } }
    }
    private func preview(at now: Date) -> some View {
        let active = model.active(at: now)
        let seconds = active?.duration ?? duration
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.active)
                    HStack(spacing: 2) {
                        ForEach(0..<seconds, id: \.self) { _ in RoundedRectangle(cornerRadius: 1).fill(Theme.cool.opacity(0.7)) }
                    }.frame(width: geometry.size.width * Double(seconds) / 60, height: 16)
                    if let active {
                        Rectangle().fill(Theme.text1).frame(width: 2).offset(x: max(0, geometry.size.width * active.progress(at: now) * Double(seconds) / 60 - 2))
                    }
                }
            }.frame(height: 24).accessibilityHidden(true)
            if let active {
                Text("Estimated time left: \(max(0, Int(ceil(active.end.timeIntervalSince(now))))) seconds").font(.subheadline.monospacedDigit()).accessibilityIdentifier("vibration.timer")
            } else if model.playing != nil {
                Text("Requested duration has elapsed. This is not a sensor confirmation.").font(.footnote).foregroundStyle(Theme.text2)
            } else { Text("\(seconds) seconds on a 60-second scale").font(.caption).foregroundStyle(Theme.text2) }
        }
    }
}
