import SwiftUI

struct ThermalLearningCard: View {
    let learning: ThermalLearning
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Learning from similar nights").font(.headline)
                Text(learning.reason).font(.footnote).foregroundStyle(Theme.text2)
                ComfortValueRow("Matched nights", value: "\(learning.nights) / \(learning.requiredNights) minimum")
                ComfortValueRow("Later validation nights", value: String(learning.validationNights))
                if let modelError = learning.modelErrorF, let baselineError = learning.baselineErrorF {
                    Text("Feedback-direction error: model \(modelError.formatted(.number.precision(.fractionLength(2)))) · simpler baseline \(baselineError.formatted(.number.precision(.fractionLength(2)))). These scores are not ideal temperatures.")
                        .font(.caption).foregroundStyle(Theme.text2)
                }
                if let suggestion = learning.suggestedOffsetF {
                    ComfortValueRow("Research suggestion", value: "\(suggestion > 0 ? "+" : "")\(suggestion.formatted())°F")
                    Text("Not applied to the bed.").font(.footnote).foregroundStyle(Theme.text2)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("comfort.thermalLearning")
    }
}
