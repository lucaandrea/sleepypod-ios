import SwiftUI

struct CoachEvidenceView: View {
    let grounding: CoachGrounding?
    var body: some View {
        if let grounding, grounding.version == 1 {
            DisclosureGroup("How these were calculated") {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(grounding.facts) { fact in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(fact.title).font(.headline)
                            Text(fact.context).font(.caption).foregroundStyle(Theme.text2)
                            Text(fact.sample).font(.subheadline)
                            Text(fact.calculation).font(.subheadline).foregroundStyle(Theme.text2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 12)
            }.tint(Theme.text1)
        } else {
            Text("Update your sleepypod server to see how these observations were calculated.")
                .font(.caption).foregroundStyle(Theme.text2)
        }
    }
}
