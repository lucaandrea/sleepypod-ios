import SwiftUI

/// Result provenance comes from this night response, independently of a requested model selection.
struct PodStageSourceDetails: View {
    let result: PodSleepStages
    var body: some View {
        DisclosureGroup("Classifier used for this view") {
            VStack(alignment: .leading, spacing: 10) {
                Text(result.sourceLabel).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if let source = result.stagedBy {
                    if let explanation = source.fallbackExplanation {
                        Text(explanation).font(.footnote).foregroundStyle(Theme.amber)
                    }
                    if let hash = source.modelHash {
                        BiometricProfileIdentity(title: "Model content hash", value: hash)
                    }
                    if let reason = source.reason {
                        Text("Reported reason: \(reason)").font(.caption).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let provenance = result.stageView?.provenance {
                    Text("Rules profile source: \(provenance.source)").font(.footnote)
                    if let generation = provenance.generation {
                        Text("Applied profile generation \(generation)").font(.footnote)
                    }
                    if let hash = provenance.stageHash {
                        BiometricProfileIdentity(title: "Rules profile hash", value: hash)
                    }
                }
                Text("The model identity describes this returned classification. Profile provenance describes the adopted processing rules. Neither is a claim of clinical accuracy.")
                    .font(.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 8)
        }.cardStyle().accessibilityIdentifier("sleep.classifierDetails")
    }
}
