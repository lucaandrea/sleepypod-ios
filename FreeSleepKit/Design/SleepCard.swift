import SwiftUI

struct SleepCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var eyebrow: String = ""
    var badge: String?
    var badgeTone: SleepBadge.Tone = .neutral
    var actionTitle: String?
    var action: (() -> Void)?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: SleepTokens.Layout.gap) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { heading.fixedSize(horizontal: true, vertical: true); Spacer(minLength: 0); accessory }
                VStack(alignment: .leading, spacing: 12) { heading; accessory }
            }
            content
        }.frame(maxWidth: .infinity, alignment: .leading).padding(SleepTokens.Layout.cardInset + 1)
            .background(SleepTheme.surface(scheme), in: .rect(cornerRadius: SleepTokens.Layout.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: SleepTokens.Layout.cardRadius).strokeBorder(SleepTheme.border(scheme)))
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !eyebrow.isEmpty { Text(eyebrow).sleepText(.eyebrow).foregroundStyle(SleepTheme.secondary) }
            Text(title).sleepText(.cardTitle).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private var accessory: some View {
        if let badge { SleepBadge(title: badge, tone: badgeTone) }
        if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(SleepButtonStyle(kind: .text)) }
    }
}
