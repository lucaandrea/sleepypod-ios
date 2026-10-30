import SwiftUI

struct PersonalHistoryPayloadView: View {
    let payload: PersonalHistoryPayload
    var body: some View {
        switch payload {
        case let .presence(seconds, exits):
            metric("Reported in bed", PersonalHistoryPresentation.duration(seconds))
            metric("Reported exits", String(exits))
            Text("Bed presence is not confirmed sleep duration.").font(.footnote).foregroundStyle(Theme.text2)
        case let .vitals(heartRate, breathing, hrv, kind):
            metric("Heart rate", PersonalHistoryPresentation.number(heartRate), unit: heartRate == nil ? nil : "bpm")
            metric("Breathing rate", PersonalHistoryPresentation.number(breathing), unit: breathing == nil ? nil : "per minute")
            metric("Pod HRV", PersonalHistoryPresentation.number(hrv), unit: hrv == nil ? nil : "ms")
            Text(kind == .windowVariability ? "Pod HRV uses variability within an inter-beat interval window. It is not interchangeable with Apple Watch HRV." : "The Pod HRV metric is unknown. Do not compare it with Apple Watch HRV.")
                .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("history.hrvMeaning")
        case let .movement(total):
            metric("Movement total", PersonalHistoryPresentation.number(total))
            Text("The source reports a movement total without a unit. It does not identify sleep stages.").font(.footnote).foregroundStyle(Theme.text2)
        }
    }
    private func metric(_ title: String, _ value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            Text(unit.map { "\(value) \($0)" } ?? value).font(.title3.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine).accessibilityIdentifier("history.metric.\(title)")
    }
}
