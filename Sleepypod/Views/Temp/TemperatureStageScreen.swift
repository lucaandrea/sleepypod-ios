import Charts
import SwiftUI

struct TemperatureStageScreen: View {
    @Environment(DeviceManager.self) private var device
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedules
    @Environment(SensorStreamService.self) private var sensor
    @Environment(UserProfile.self) private var profile
    @State private var cameraReset = 0
    @State private var previewFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let timeline = TemperatureTimeline(schedules: schedules.schedules, timezone: settings.timeZone, now: context.date)
            let previewDate = previewFraction.map { timeline.date(at: $0) }
            let stale = sensor.bedTempUpdatedAt.map { context.date.timeIntervalSince($0) >= ThermalBedCard.staleSeconds } ?? true
            let left = values(for: .left, timeline: timeline, date: previewDate, stale: stale)
            let right = values(for: .right, timeline: timeline, date: previewDate, stale: stale)
            ScrollView {
                VStack(spacing: 18) {
                    HStack(spacing: 10) {
                        sideLabel(.left, preview: previewDate.map { timeline.state(for: .left, at: $0) })
                        sideLabel(.right, preview: previewDate.map { timeline.state(for: .right, at: $0) })
                    }
                    ZStack(alignment: .bottomTrailing) {
                        ThermalBedSceneView(left: left, right: right, interactive: true,
                                            selectedSide: device.isLinked ? nil : device.selectedSide.primarySide,
                                            autoReturn: profile.stageAutoReturn, resetCamera: cameraReset) { side in
                            if !device.isLinked { device.selectSide(side == .left ? .left : .right) }
                        }
                        .frame(height: 310)
                        .accessibilityLabel("Interactive mattress")
                        .accessibilityHint("Drag sideways to rotate. Drag with two fingers to tilt. Pinch to zoom. Select a side using the buttons above.")
                        Button("Reset view", systemImage: "arrow.counterclockwise") { cameraReset += 1 }
                            .font(.caption).buttonStyle(.bordered).padding(8)
                    }
                    .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 24))
                    ZStack {
                        VStack(spacing: 18) {
                            if profile.stageZones != .off {
                                zoneReadings(left: left, right: right)
                                Text(stale ? "Measured regions · no fresh readings" : "Measured regions · outer, center, inner on each side")
                                    .font(.caption2).foregroundStyle(Theme.text3)
                            }
                            TempControlsView()
                            TemperatureOwnershipView()
                        }
                        .opacity(previewDate == nil ? 1 : 0)
                        .disabled(previewDate != nil)
                        .accessibilityHidden(previewDate != nil)
                        if previewDate != nil {
                            VStack(spacing: 12) {
                                Label("Schedule preview", systemImage: "clock").font(.subheadline.weight(.semibold))
                                Text("Saved targets only. Live sensor colors return when you leave preview.")
                                    .font(.footnote).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                                Button("Back to live") { previewFraction = nil }
                                    .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                            }
                        }
                    }
                    timelineCard(timeline, preview: previewDate)
                    if APIBackend.current != .freeSleep { NextAlarmCard(side: device.selectedSide.primarySide) }
                    if APIBackend.current != .freeSleep { TemperatureContextCards(side: device.selectedSide.primarySide) }
                }.padding(16)
            }.refreshable { await device.fetchStatus(); await schedules.fetchSchedules() }
        }
    }

    private func values(for side: Side, timeline: TemperatureTimeline, date: Date?, stale: Bool) -> [Double?] {
        if let date {
            let state = timeline.state(for: side, at: date)
            let value = state.powered == false ? nil : state.temperature.map(Double.init)
            return Array(repeating: value, count: 3)
        }
        return stale ? ThermalZones.none : ThermalZones.fahrenheit(side == .left ? sensor.leftTemps : sensor.rightTemps)
    }

    private func sideLabel(_ side: Side, preview: TemperatureTimeline.State?) -> some View {
        let status = device.deviceStatus?.status(for: side)
        let target = preview == nil ? status?.targetTemperatureF : preview?.temperature
        let selected = device.isLinked || device.selectedSide.primarySide == side
        return Button {
            if !device.isLinked { device.selectSide(side == .left ? .left : .right) }
        } label: {
            VStack(spacing: 5) {
                Text(settings.sideName(for: side)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(target.map { profile.temperatureDisplay.text($0, unit: settings.temperatureFormat) } ?? "—")
                    .font(.mono(30, weight: .light, relativeTo: .title))
                Text(stateWord(status: status, preview: preview)).font(.mono(10, relativeTo: .caption2))
                    .foregroundStyle(Theme.text2)
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(selected ? Theme.card : Theme.background)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? Theme.text2 : Theme.track, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("Select \(settings.sideName(for: side))")
            .accessibilityValue(target.map { profile.temperatureDisplay.text($0, unit: settings.temperatureFormat, includeUnit: true) } ?? "Unknown")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func stateWord(status: SideStatus?, preview: TemperatureTimeline.State?) -> String {
        if let preview { return preview.powered == false ? "SCHEDULED OFF" : "SAVED TARGET" }
        guard let status else { return "UNAVAILABLE" }
        guard status.isOn else { return "OFF" }
        guard let target = status.targetTemperatureF, let bed = status.currentTemperatureF else { return "ON" }
        return TemperatureConversion.stateWord(target: target, bed: bed, isOn: true)
    }
    private func zoneReadings(left: [Double?], right: [Double?]) -> some View {
        VStack(spacing: 8) {
            ForEach(Side.allCases.filter { profile.stageZones == .always || device.isLinked || device.selectedSide.primarySide == $0 }) { side in
                let readings = side == .left ? left : right
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        let value = readings[index]
                        VStack(spacing: 5) {
                            Text(value.map { TemperatureConversion.displayTemp(Int($0.rounded()), format: settings.temperatureFormat.degreeUnit) } ?? "—")
                                .font(.mono(16, relativeTo: .subheadline))
                            Text("\(side == .left ? "L" : "R") \(["outer", "center", "inner"][index])")
                                .font(.caption2)
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(TempRamp.color(value).opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
    private func timelineCard(_ timeline: TemperatureTimeline, preview: Date?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("TONIGHT")
                Spacer()
                if let preview { Text(clock(preview)).font(.mono(13, relativeTo: .caption)) }
                else { Label("Live", systemImage: "circle.fill").font(.caption).foregroundStyle(Theme.green) }
            }
            Chart {
                ForEach(Side.allCases) { side in
                    ForEach(timeline.samples(for: side)) { sample in
                        LineMark(x: .value("Time", sample.date), y: .value("°F", sample.temperature), series: .value("Side", side.rawValue))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: side == .left ? [] : [5, 4]))
                            .foregroundStyle(side == .left ? Theme.cool : Theme.warm)
                    }
                }
                if let preview { RuleMark(x: .value("Preview", preview)).foregroundStyle(Theme.text1) }
            }
            .chartXScale(domain: timeline.range).chartYScale(domain: 55...110).chartXAxis(.hidden)
            .chartYAxis(.hidden).frame(height: 80)
            .accessibilityLabel("Saved temperature schedule, left in blue and right in warm tones")
            HStack(spacing: 18) {
                Label(settings.leftName, systemImage: "minus").foregroundStyle(Theme.cool)
                Label(settings.rightName, systemImage: "ellipsis").foregroundStyle(Theme.warm)
            }.font(.caption2)
            Slider(value: Binding(get: { previewFraction ?? 0 }, set: { previewFraction = $0 }), in: 0...1)
                .accessibilityLabel("Preview tonight's schedule").accessibilityValue(preview.map(clock) ?? "Live")
                .disabled(schedules.schedules == nil)
            HStack { Text(clock(timeline.range.lowerBound)); Spacer(); Text(clock(timeline.range.upperBound)) }
                .font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text2)
            Text("Drag to preview · \(settings.timeZone)").font(.caption2).foregroundStyle(Theme.text3)
            if schedules.schedules == nil { Text(schedules.error ?? "No schedule loaded.").font(.footnote).foregroundStyle(Theme.text2) }
        }.cardStyle()
    }
    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: settings.timeZone)
        return formatter.string(from: date)
    }
}
