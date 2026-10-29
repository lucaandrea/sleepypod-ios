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
                    Text("Comfort-label error: model \(modelError.formatted(.number.precision(.fractionLength(2))))°F · simpler baseline \(baselineError.formatted(.number.precision(.fractionLength(2))))°F")
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
