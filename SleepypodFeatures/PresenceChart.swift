import SwiftUI

struct PresenceChart: View {
    let nights: [SleepAnalytics.Night]
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(nights) { night in
                        bar(night, width: columnWidth(in: geometry.size.width))
                    }
                }.frame(height: 154, alignment: .bottom)
            }.scrollIndicators(.hidden)
        }.frame(height: 170)
    }
    private func columnWidth(in available: CGFloat) -> CGFloat {
        let gaps = CGFloat(max(0, nights.count - 1)) * 6
        return max(8, min(55, (available - gaps) / CGFloat(max(1, nights.count))))
    }
    private func barHeight(_ minutes: Double?) -> CGFloat {
        guard let minutes else { return 4 }
        let percent = max(3.0, min(100.0, minutes / 720.0 * 100.0))
        return CGFloat(percent / 100.0 * 154.0)
    }
    private func bar(_ night: SleepAnalytics.Night, width: CGFloat) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 6)
            .fill(night.occupiedMinutes == nil ? Theme.border1 : Theme.text1)
            .opacity(0.7).frame(width: width, height: barHeight(night.occupiedMinutes))
            .accessibilityLabel("\(night.date): \(SleepAnalytics.duration(night.occupiedMinutes)) bed presence")
    }
}
