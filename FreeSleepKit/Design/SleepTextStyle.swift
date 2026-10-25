import SwiftUI

struct SleepTextStyle: ViewModifier {
    let style: SleepTypography
    @ScaledMetric private var size: CGFloat
    init(_ style: SleepTypography) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relative)
    }
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: style.weight)).tracking(style.tracking * size / style.size)
            .lineSpacing(style == .body || style == .small ? size * 0.4 : 0)
    }
}

extension View {
    func sleepText(_ style: SleepTypography) -> some View { modifier(SleepTextStyle(style)) }
}
