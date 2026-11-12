import SwiftUI

/// Keeps full-size, multiline action labels inside their control at accessibility sizes.
struct FeatureActionButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            if primary {
                paddedLabel(configuration).foregroundStyle(Theme.background)
                    .background(Theme.text1, in: shape).contentShape(shape)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            } else {
                paddedLabel(configuration).foregroundStyle(Theme.text1)
                    .chromeSurface(shape).contentShape(shape)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            }
        } else if primary {
            configuration.label.font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(Theme.background).background(Theme.text1, in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
                .contentShape(Capsule())
        } else {
            configuration.label.font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(Theme.text1).chromeSurface()
                .opacity(isEnabled ? 1 : 0.45)
        }
    }

    private func paddedLabel(_ configuration: Configuration) -> some View {
        configuration.label.font(.headline).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 56)
    }
}
