import SwiftUI

struct SleepPage<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sleepWideLayout) private var wide
    let title: String
    var subtitle: String = ""
    var badge: String?
    var badgeTone: SleepBadge.Tone = .neutral
    var badgeDot = false
    var narrow = false
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SleepTokens.Layout.gap) {
                if model.demo {
                    Label("Demo · sample data and simulated controls", systemImage: "info.circle")
                        .sleepText(.small).foregroundStyle(SleepTheme.info).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 14).frame(minHeight: 50)
                        .background(SleepTheme.info.opacity(0.06), in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SleepTheme.info.opacity(0.18)))
                }
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { heading.fixedSize(horizontal: true, vertical: true); Spacer(minLength: 0); statusBadge }
                        VStack(alignment: .leading, spacing: 16) { heading; statusBadge }
                    }
                    if !subtitle.isEmpty { Text(subtitle).sleepText(.body).foregroundStyle(SleepTheme.secondary) }
                }
                content
            }.padding(.horizontal, wide ? SleepTokens.Layout.widePageInset : SleepTokens.Layout.pageInset)
                .padding(.vertical, wide ? SleepTokens.Layout.widePageInset : SleepTokens.Layout.pageTop)
                .frame(maxWidth: narrow ? SleepTokens.Layout.narrowPageWidth : SleepTokens.Layout.pageWidth)
                .frame(maxWidth: .infinity)
        }.background(SleepTheme.canvas(scheme))
    }
    private var heading: some View {
        Text(title).sleepText(wide ? .widePageTitle : .pageTitle).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var statusBadge: some View {
        if let badge { SleepBadge(title: badge, tone: badgeTone, dot: badgeDot) }
    }
}
