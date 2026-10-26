import SwiftUI

/// Dragging edits only the local draft; the existing Save and conflict review still apply.
struct EditableTemperatureCurve: View {
    @Binding var points: [CurvePoint]
    var edit: (CurvePoint) -> Void
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var dragDomain: CurveChartProjection?
    @State private var selected: UUID?
    private var domain: CurveChartProjection { dragDomain ?? CurveChartProjection(points: points) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("TEMPERATURE CURVE")
            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 44), height = max(1, geometry.size.height - 44)
                ZStack(alignment: .topLeading) {
                    Path { path in
                        let ordered = points.sorted { domain.minute($0) < domain.minute($1) }
                        for (index, point) in ordered.enumerated() {
                            let position = position(point, width: width, height: height)
                            if index == 0 { path.move(to: position) }
                            else {
                                path.addLine(to: CGPoint(x: position.x, y: self.position(ordered[index - 1], width: width, height: height).y))
                                path.addLine(to: position)
                            }
                        }
                    }.stroke(LinearGradient(colors: [Theme.cool, Theme.warm], startPoint: .leading, endPoint: .trailing), style: .init(lineWidth: 2.5, lineJoin: .round))
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        Button { selected = point.id; edit(point) } label: {
                            Circle().fill(TempColor.forScheduled(Int(point.temperature)))
                                .frame(width: selected == point.id ? 16 : 12, height: selected == point.id ? 16 : 12)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .position(position(point, width: width, height: height))
                            .accessibilityLabel("Set point \(index + 1)")
                            .accessibilityValue(label(point))
                            .accessibilityIdentifier("curve.handle.\(index)")
                            .accessibilityHint("Open to edit time and temperature, or adjust temperature directly.")
                            .accessibilityAdjustableAction { direction in
                                let change = direction == .increment ? 1 : -1
                                var updated = point
                                updated.temperature = Double(TemperatureDisplay.degrees.step(Int(point.temperature), by: change, unit: settings.temperatureFormat))
                                replace(updated)
                            }
                            .accessibilityAction(named: "15 minutes earlier") { shift(point, by: -15) }
                            .accessibilityAction(named: "15 minutes later") { shift(point, by: 15) }
                            .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("curveEditor.chart"))
                                .onChanged { movement in
                                    if dragDomain == nil { dragDomain = CurveChartProjection(points: points) }
                                    selected = point.id
                                    replace(domain.moved(point, horizontal: (movement.location.x - 22) / width, vertical: (movement.location.y - 22) / height))
                                }.onEnded { _ in dragDomain = nil })
                    }
                }.coordinateSpace(name: "curveEditor.chart")
            }.frame(height: typeSize.isAccessibilitySize ? 240 : 180)
            let labels = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
            labels {
                Text(DisplayTime.clock(CurvePoint.clock(Int(domain.start))))
                if !typeSize.isAccessibilitySize { Spacer() }
                Text(DisplayTime.clock(CurvePoint.clock(Int(domain.end))))
            }.font(.mono(11, relativeTo: .caption)).foregroundStyle(Theme.text3)
            if let point = points.first(where: { $0.id == selected }) {
                Text(label(point)).font(.mono(14, relativeTo: .subheadline)).accessibilityIdentifier("curve.dragValue")
            }
            Text("Drag a point to change its time and temperature. Times snap to 15 minutes. Tap a point for precise editing.")
                .font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }.cardStyle()
    }
    private func position(_ point: CurvePoint, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: 22 + domain.horizontal(point) * width, y: 22 + domain.vertical(point) * height)
    }
    private func label(_ point: CurvePoint) -> String {
        "\(DisplayTime.clock(point.time)) · \(TemperatureDisplay.degrees.text(Int(point.temperature), unit: settings.temperatureFormat, includeUnit: true))"
    }
    private func replace(_ point: CurvePoint) {
        guard let index = points.firstIndex(where: { $0.id == point.id }) else { return }
        points[index] = point
    }
    private func shift(_ point: CurvePoint, by minutes: Int) {
        var updated = point; updated.time = CurvePoint.clock(point.minutes + minutes); replace(updated)
    }
}
