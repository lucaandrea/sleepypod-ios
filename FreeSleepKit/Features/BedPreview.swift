import SwiftUI

struct BedPreview: View {
    let head: Double
    let feet: Double
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 320, geometry.size.height / 140)
            let origin = CGPoint(x: (geometry.size.width - 320 * scale) / 2, y: (geometry.size.height - 140 * scale) / 2)
            let transform = CGAffineTransform(scaleX: scale, y: scale).concatenating(.init(translationX: origin.x, y: origin.y))
            Path { path in
                path.move(to: CGPoint(x: 35, y: 114)); path.addLine(to: CGPoint(x: 285, y: 114))
                for horizontal in [60.0, 260.0] {
                    path.move(to: CGPoint(x: horizontal, y: 114)); path.addLine(to: CGPoint(x: horizontal, y: 128))
                }
            }.applying(transform).stroke(SleepTheme.text.opacity(0.16), style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round))
            profile(baseline: 98).applying(transform)
                .stroke(SleepTheme.text.opacity(0.12), style: StrokeStyle(lineWidth: 18 * scale, lineCap: .round, lineJoin: .round))
            profile(baseline: 91).applying(transform)
                .stroke(SleepTheme.bedLine, style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round))
        }.frame(height: 140).accessibilityLabel("Position preview: head \(Int(head)) degrees, feet \(Int(feet)) degrees")
    }
    private func profile(baseline: Double) -> Path {
        let headRise = sin(head * .pi / 180) * 90, feetRise = sin(feet * .pi / 180) * 70
        return Path { path in
            path.move(to: CGPoint(x: 40, y: baseline - headRise))
            path.addLine(to: CGPoint(x: 130, y: baseline)); path.addLine(to: CGPoint(x: 185, y: baseline))
            path.addLine(to: CGPoint(x: 245, y: baseline - feetRise)); path.addLine(to: CGPoint(x: 284, y: baseline - feetRise * 0.5))
        }
    }
}
