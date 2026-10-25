import SwiftUI

struct SleepButtonStyle: ButtonStyle {
    enum Kind { case primary, outlined, text }
    var kind: Kind = .outlined
    var fill = false
    var horizontalPadding: CGFloat = 16
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.sleepText(.button)
            .padding(.horizontal, horizontalPadding).padding(.vertical, 10)
            .frame(maxWidth: fill ? .infinity : nil, minHeight: SleepTokens.Layout.controlHeight)
            .foregroundStyle(foreground(destructive: configuration.role == .destructive))
            .background(background.opacity(configuration.isPressed ? 0.8 : 1), in: .rect(cornerRadius: SleepTokens.Layout.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: SleepTokens.Layout.controlRadius)
                .strokeBorder(kind == .outlined ? SleepTheme.border(scheme) : .clear))
            .contentShape(.rect(cornerRadius: SleepTokens.Layout.controlRadius))
    }
    private var background: Color {
        kind == .primary ? (enabled ? SleepTheme.primaryButton : SleepTheme.text.opacity(0.12)) : .clear
    }
    private func foreground(destructive: Bool) -> Color {
        if !enabled { return SleepTheme.text.opacity(0.3) }
        if kind == .primary { return SleepTheme.primaryButtonText }
        return destructive ? SleepTheme.error : kind == .text ? SleepTheme.accent : SleepTheme.text
    }
}
