import SwiftUI
import Charts

struct SensorWaveformReplayView: View {
    let frames: [PiezoDualFrame]
    let sides: [Side]
    @State private var inspection = 0.5
    private var points: [SensorWaveformSample] { SensorWaveformSample.points(frames: frames, sides: sides) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if points.isEmpty { Text("No waveform samples in this window").font(.footnote).foregroundStyle(Theme.text2).frame(minHeight: 130) }
            else {
                Chart(points) { point in
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: point.time)), y: .value("Raw signal", point.value), series: .value("Run", point.run))
                        .foregroundStyle(by: .value("Side", point.side == .left ? "Left" : "Right"))
                }
                .chartForegroundStyleScale(["Left": Theme.cooling, "Right": Theme.warming])
                .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 150)
                Slider(value: $inspection, in: 0...1) { Text("Waveform sample inspection") }.accessibilityIdentifier("sensors.waveformInspection")
                ForEach(sides) { side in
                    let samples = points.filter { $0.side == side }
                    let start = samples.first?.time ?? 0, end = samples.last?.time ?? start
                    let time = start + inspection * (end - start)
                    if let sample = samples.min(by: { abs($0.time - time) < abs($1.time - time) }) {
                        Text("\(side.displayName) · \(Int(sample.value)) · \(Date(timeIntervalSince1970: sample.time).formatted(date: .omitted, time: .standard))")
                            .font(.caption.monospacedDigit())
                    }
                }
                Text("Retained min/max samples; signal units are raw firmware counts.").font(.caption).foregroundStyle(Theme.text2)
            }
        }
    }
}

struct SensorWaveformControls: View {
    @Environment(SensorStreamService.self) private var sensor
    @Environment(\.scenePhase) private var scenePhase
    @State private var position: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let range = sensor.waveformReplay.range {
                Text("Available: \(clock(range.min)) – \(clock(range.max))").font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
                Slider(value: Binding(get: { min(range.max, max(range.min, position ?? range.max)) }, set: { position = $0 }), in: range.min...range.max) { Text("Piezo replay position") } onEditingChanged: { editing in
                    if !editing, let position { Task { await sensor.seekWaveform(at: position) } }
                }.disabled(!sensor.isConnected).accessibilityIdentifier("sensors.waveformPosition")
                Button("Inspect recent waveform") { Task { await sensor.seekWaveform(at: max(range.min, range.max - 10)) } }
                    .disabled(!sensor.isConnected).accessibilityIdentifier("sensors.waveformReplay")
            } else { Text("Waiting for the controller’s waveform range").font(.caption).foregroundStyle(Theme.text2) }
            if sensor.waveformReplay.loading { ProgressView("Loading waveform…") }
            if sensor.waveformReplay.frames != nil {
                Button("Back to live") { position = nil; sensor.waveformReplay.goLive() }.accessibilityIdentifier("sensors.waveformLive")
            }
            if let error = sensor.waveformReplay.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
        }
        .task(id: "\(sensor.isConnected)-\(scenePhase)") {
            guard sensor.isConnected, scenePhase == .active else { return }
            repeat {
                await sensor.requestWaveformRange()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func clock(_ seconds: Double) -> String { Date(timeIntervalSince1970: seconds).formatted(date: .omitted, time: .standard) }
}
