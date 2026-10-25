import SwiftUI

struct CoachEvidenceView: View {
    let grounding: CoachGrounding?
    var body: some View {
        if let grounding, grounding.version == 1 {
            DisclosureGroup("How these were calculated") {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(grounding.facts) { fact in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(fact.title).sleepText(.cardTitle)
                            Text(fact.context).sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                            Text(fact.sample).sleepText(.small)
                            Text(fact.calculation).sleepText(.small).foregroundStyle(SleepTheme.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 12)
            }.tint(SleepTheme.accent)
        } else {
            Text("Update your Free Sleep server to see how these observations were calculated.")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
        }
    }
}
