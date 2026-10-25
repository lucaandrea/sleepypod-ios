import SwiftUI

// Matches the web control while delegating assistive interactions to a native Slider.
struct SleepSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    @Environment(\.isEnabled) private var enabled
    @Environment(\.layoutDirection) private var direction
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let fraction = max(0, min(1, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
            let position = direction == .rightToLeft ? 1 - fraction : fraction
            let tint = enabled ? SleepTheme.accent : SleepTheme.secondary.opacity(0.4)
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.3)).frame(height: 4)
                Capsule().fill(tint).frame(width: geometry.size.width * fraction, height: 4)
                    .frame(maxWidth: .infinity, alignment: direction == .rightToLeft ? .trailing : .leading)
                Circle().fill(tint).frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .overlay(Circle().stroke(tint.opacity(dragging ? 0.15 : 0), lineWidth: 12))
                    .position(x: geometry.size.width * position, y: geometry.size.height / 2)
            }.frame(maxHeight: .infinity).contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard enabled, geometry.size.width > 0 else { return }
                    dragging = true
                    let portion = max(0, min(1, event.location.x / geometry.size.width))
                    let directed = direction == .rightToLeft ? 1 - portion : portion
                    let proposed = range.lowerBound + directed * (range.upperBound - range.lowerBound)
                    value = max(range.lowerBound, min(range.upperBound, (proposed / step).rounded() * step))
                }.onEnded { _ in dragging = false })
        }.frame(height: SleepTokens.Layout.controlHeight)
            .accessibilityRepresentation {
                Slider(value: $value, in: range, step: step) { Text(title) }.disabled(!enabled)
            }
    }
}
