import SwiftUI

struct PiezoWaveformView: View {
    @Environment(SensorStreamService.self) private var sensor
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var sweep = SweepState()
    @State private var showLeft = true
    @State private var showRight = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PIEZO WAVEFORM").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
            channel("Left channel", visible: $showLeft, color: Theme.cooling, identifier: "sensors.waveformLeft")
            channel("Right channel", visible: $showRight, color: Theme.warming, identifier: "sensors.waveformRight")
            Text(waveformSummary).font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
            if let frames = sensor.waveformReplay.frames {
                SensorWaveformReplayView(frames: frames, sides: (showLeft ? [Side.left] : []) + (showRight ? [Side.right] : []))
            } else {
                // Snapshot on main thread — Canvas closure captures these value types
                let left = PiezoSweep.Channel(first: sensor.piezoLeftEnd - sensor.piezoLeft.count, samples: showLeft ? sensor.piezoLeft : [])
                let right = PiezoSweep.Channel(first: sensor.piezoRightEnd - sensor.piezoRight.count, samples: showRight ? sensor.piezoRight : [])
                let hz = Double(sensor.piezoHz)
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: left.samples.isEmpty && right.samples.isEmpty)) { timeline in
                    scopeCanvas(sweep.frame(left: left, right: right, hz: hz, at: timeline.date))
                }
                .frame(height: 130)
                .allowsHitTesting(false)
            }
            SensorWaveformControls()
        }
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }

    private var waveformSummary: String {
        guard let frames = sensor.waveformReplay.frames else { return "LIVE · \(sensor.piezoHz) Hz · L \(sensor.piezoLeft.count) · R \(sensor.piezoRight.count)" }
        let rates = Set(frames.map(\.freq))
        let frequency = rates.count == 1 ? "\(rates.first ?? 0) Hz" : "variable sample rate"
        return "REPLAY · \(frames.count) frames · \(frequency)"
    }

    @ViewBuilder private func channel(_ title: String, visible: Binding<Bool>, color: Color, identifier: String) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                Toggle(title, isOn: visible).labelsHidden().tint(color).accessibilityIdentifier(identifier)
            }
        } else { Toggle(title, isOn: visible).tint(color).accessibilityIdentifier(identifier) }
    }

    private func scopeCanvas(_ frame: SweepFrame?) -> some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard w > 0, h > 0 else { return }

            drawGrid(context: context, w: w, h: h)

            guard let frame else {
                context.draw(
                    Text("Waiting for piezo data").font(.system(size: 10)).foregroundColor(Theme.textMuted),
                    at: CGPoint(x: w / 2, y: h / 2)
                )
                return
            }

            let range = frame.range.hi - frame.range.lo
            guard range > 0, range.isFinite else { return }
            let yOf = { (v: Double) -> Double in
                let y = Double(h) * (1 - (v - frame.range.lo) / range)
                return y.isFinite ? min(max(y, 0), Double(h)) : Double(h) / 2
            }

            for (channel, c) in [(frame.left, Theme.cooling), (frame.right, Theme.warming)] {
                guard channel.samples.count >= PiezoSweep.minSamples else { continue }
                for run in PiezoSweep.runs(channel, play: frame.play, geometry: frame.geometry, width: Double(w), yOf: yOf) {
                    guard let path = tracePath(run) else { continue }
                    context.stroke(path, with: .color(c.opacity(0.08)), lineWidth: 6)
                    context.stroke(path, with: .color(c.opacity(0.3)), lineWidth: 2.5)
                    context.stroke(path, with: .color(c), lineWidth: 0.8)
                }
            }

            // Sweep cursor
            let x = PiezoSweep.cursorX(play: frame.play, geometry: frame.geometry, width: Double(w))
            var cursor = Path(); cursor.move(to: CGPoint(x: x, y: 0)); cursor.addLine(to: CGPoint(x: x, y: h))
            context.stroke(cursor, with: .color(Theme.textMuted), lineWidth: 1)
        }
    }

    private func drawGrid(context: GraphicsContext, w: CGFloat, h: CGFloat) {
        let minor = Theme.cardBorder.opacity(0.5)
        let major = Theme.cardBorder

        let cols = max(1, Int(w / 25))
        for i in 1..<cols {
            let x = w * CGFloat(i) / CGFloat(cols)
            var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
            context.stroke(p, with: .color(minor), lineWidth: 0.5)
        }
        for i in 1..<8 {
            let y = h * CGFloat(i) / 8
            var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
            context.stroke(p, with: .color(minor), lineWidth: 0.5)
        }

        var hc = Path(); hc.move(to: CGPoint(x: 0, y: h / 2)); hc.addLine(to: CGPoint(x: w, y: h / 2))
        context.stroke(hc, with: .color(major), lineWidth: 0.8)
        var vc = Path(); vc.move(to: CGPoint(x: w / 2, y: 0)); vc.addLine(to: CGPoint(x: w / 2, y: h))
        context.stroke(vc, with: .color(major), lineWidth: 0.8)
    }

    private func tracePath(_ pts: [CGPoint]) -> Path? {
        guard pts.count >= 2 else { return nil }

        var path = Path()
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let cp1x = p1.x + (p2.x - p0.x) / 6
            let cp1y = p1.y + (p2.y - p0.y) / 6
            let cp2x = p2.x - (p3.x - p1.x) / 6
            let cp2y = p2.y - (p3.y - p1.y) / 6
            if cp1x.isFinite && cp1y.isFinite && cp2x.isFinite && cp2y.isFinite {
                path.addCurve(to: p2,
                              control1: CGPoint(x: cp1x, y: cp1y),
                              control2: CGPoint(x: cp2x, y: cp2y))
            } else {
                path.addLine(to: p2)
            }
        }
        return path
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).font(.system(size: 8)).foregroundColor(Theme.textMuted)
        }
    }
}

/// Everything one Canvas pass needs, as value types.
private struct SweepFrame {
    let left: PiezoSweep.Channel
    let right: PiezoSweep.Channel
    let play: Double
    let range: (lo: Double, hi: Double)
    let geometry: PiezoSweep.Geometry
}

/// Sweep cursor and displayed vertical range, carried across animation frames.
/// Mutated while building each frame; nothing observes it, so it never triggers a render.
@MainActor
private final class SweepState {
    private var play: Double?
    private var shown: (lo: Double, hi: Double)?
    private var target: (lo: Double, hi: Double)?
    private var targetKey: [Int] = []
    private var lastDate: Date?

    func frame(left: PiezoSweep.Channel, right: PiezoSweep.Channel, hz: Double, at date: Date) -> SweepFrame? {
        let visible = [left, right].filter { $0.samples.count >= PiezoSweep.minSamples }
        guard !visible.isEmpty, hz > 0 else {
            play = nil
            shown = nil
            lastDate = nil
            return nil
        }
        let dt = lastDate.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        lastDate = date

        let first = visible.map(\.first).min() ?? 0
        let end = visible.map(\.end).max() ?? 0
        let next = PiezoSweep.advance(play: play, first: first, end: end, hz: hz, dt: dt)
        play = next

        let geometry = PiezoSweep.geometry(hz: hz)
        // Recompute the target only when new samples land, not on every animation frame
        let key = [left.first, left.end, right.first, right.end]
        if key != targetKey || target == nil {
            target = PiezoSweep.robustRange(visible, fromN: end - geometry.sweep)
            targetKey = key
        }
        guard let target else { return nil }
        let range = shown.map { PiezoSweep.ease(shown: $0, target: target, dt: dt) } ?? target
        shown = range

        return SweepFrame(left: left, right: right, play: next, range: range, geometry: geometry)
    }
}
