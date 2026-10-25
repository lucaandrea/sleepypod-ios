import SwiftUI

struct PresenceChart: View {
    let nights: [SleepAnalytics.Night]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - CGFloat(max(0, nights.count - 1)) * 6
            let width = max(8, min(55, available / CGFloat(max(1, nights.count))))
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(nights) { night in
                        let height = night.occupiedMinutes.map { max(3, min(100, $0 / 720 * 100)) / 100 * 154 } ?? 4
                        UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 6)
                            .fill(night.occupiedMinutes == nil ? SleepTheme.border(scheme) : SleepTheme.accent)
                            .opacity(0.7).frame(width: width, height: height)
                            .accessibilityLabel("\(night.date): \(SleepAnalytics.duration(night.occupiedMinutes)) bed presence")
                    }
                }.frame(height: 154, alignment: .bottom)
            }.scrollIndicators(.hidden)
        }.frame(height: 170)
    }
}
