import SwiftUI

struct SleepBadge: View {
    enum Tone { case neutral, success, info, error, warning }
    let title: String
    var tone: Tone = .neutral
    var dot = false
    private var tint: Color {
        switch tone {
        case .neutral: SleepTheme.secondary
        case .success: SleepTheme.success
        case .info: SleepTheme.info
        case .error: SleepTheme.error
        case .warning: SleepTheme.warning
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(tint).frame(width: 6, height: 6).accessibilityHidden(true) }
            Text(title).sleepText(.badge)
        }.padding(.horizontal, 8).padding(.vertical, 4).frame(minHeight: SleepTokens.Layout.badgeHeight)
            .foregroundStyle(tint).background(tint.opacity(0.1), in: .rect(cornerRadius: SleepTokens.Layout.badgeRadius))
            .overlay(RoundedRectangle(cornerRadius: SleepTokens.Layout.badgeRadius).strokeBorder(tint.opacity(0.16)))
            .fixedSize(horizontal: false, vertical: true)
    }
}
