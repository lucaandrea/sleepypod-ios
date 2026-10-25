import SwiftUI

struct RoutineTimeline: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    let schedule: DailySchedule
    private var points: [RoutinePoint] { RoutinePlan.points(schedule) }
    private var unit: String { model.settings?.temperatureFormat == "celsius" ? "C" : "F" }
    var body: some View {
        if let end = points.last {
            GeometryReader { geometry in
                let horizontal = { (minutes: Int) in (38 + Double(minutes) / Double(end.minutes) * 330) / 400 * geometry.size.width }
                let vertical = { (temperature: Int) in (112 - Double(temperature - 55) / 55 * 88) / 142 * geometry.size.height }
                ZStack(alignment: .topLeading) {
                    ForEach([55, 80, 110], id: \.self) { temperature in
                        Path { path in path.move(to: .init(x: horizontal(0), y: vertical(temperature))); path.addLine(to: .init(x: horizontal(end.minutes), y: vertical(temperature))) }
                            .stroke(SleepTheme.border(scheme), lineWidth: 1)
                        Text("\(model.temperatureLabel(Double(temperature)))°\(unit)").font(.system(size: 11 * geometry.size.width / 400))
                            .foregroundStyle(SleepTheme.secondary).position(x: 14 / 400 * geometry.size.width, y: vertical(temperature))
                    }
                    Path { path in
                        for (index, point) in points.enumerated() {
                            let destination = CGPoint(x: horizontal(point.minutes), y: vertical(point.temperature))
                            if index == 0 { path.move(to: destination) }
                            else { path.addLine(to: .init(x: destination.x, y: vertical(points[index - 1].temperature))); path.addLine(to: destination) }
                        }
                    }.stroke(SleepTheme.accent, style: .init(lineWidth: 3, lineJoin: .round))
                    if schedule.alarm.enabled, let alarm = RoutinePlan.offset(schedule.alarm.time, from: schedule.power.on), alarm > 0, alarm < end.minutes {
                        Path { path in path.move(to: .init(x: horizontal(alarm), y: 20 / 142 * geometry.size.height)); path.addLine(to: .init(x: horizontal(alarm), y: 114 / 142 * geometry.size.height)) }
                            .stroke(SleepTheme.secondary, style: .init(lineWidth: 1, dash: [3, 4]))
                    }
                    HStack {
                        Text(schedule.power.on); Spacer()
                        Text(schedule.power.off + (schedule.power.off < schedule.power.on ? " +1 day" : ""))
                    }.font(.system(size: 12 * geometry.size.width / 400)).foregroundStyle(SleepTheme.secondary)
                        .padding(.leading, 38 / 400 * geometry.size.width).padding(.trailing, 32 / 400 * geometry.size.width)
                        .frame(height: geometry.size.height, alignment: .bottom)
                }.opacity(schedule.power.enabled ? 1 : 0.45)
            }.aspectRatio(400 / 142, contentMode: .fit)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Planned temperature. " + points.dropLast().map { "\($0.time): \(model.temperatureLabel(Double($0.temperature))) degrees \(unit)" }.joined(separator: "; ") + ". Off at \(schedule.power.off).")
            Text((schedule.power.enabled ? "Planned targets · actual temperature changes gradually." : "Routine off · this plan runs when enabled.")
                 + (schedule.alarm.enabled ? " Vibration at \(schedule.alarm.time)." : ""))
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        } else { Text("Choose different turn-on and turn-off times to preview your night.").foregroundStyle(SleepTheme.secondary) }
    }
}
