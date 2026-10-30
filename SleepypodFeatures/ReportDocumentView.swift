import SwiftUI

struct ReportDocumentView: View {
    let document: ReportDocument
    let facts: [SleepFact]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(document.blocks) { block in
                VStack(alignment: .leading, spacing: 10) {
                    switch block.kind {
                    case .heading(let level):
                        Text(ReportDocument.inline(block.text)).font(level <= 2 ? .title3.bold() : .headline)
                            .accessibilityAddTraits(.isHeader)
                    case .paragraph:
                        Text(ReportDocument.inline(block.text)).font(.body).lineSpacing(4)
                    case .bullet(let marker):
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(marker).foregroundStyle(Theme.reportAccent).bold().accessibilityHidden(true)
                            Text(ReportDocument.inline(block.text)).font(.body).lineSpacing(4)
                        }
                    }
                    ForEach(block.evidence, id: \.self) { identifier in
                        if let fact = facts.first(where: { $0.id == identifier }) {
                            DisclosureGroup {
                                Text(fact.text).font(.subheadline).foregroundStyle(Theme.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("report.evidence.\(identifier)")
                            } label: {
                                Label(ReportEvidenceLabel.title(identifier), systemImage: identifier.hasPrefix("health.") ? "heart.text.clipboard" : "bed.double")
                                    .font(.caption.weight(.medium)).foregroundStyle(Theme.reportAccent)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Theme.reportAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            }.accessibilityIdentifier("report.source.\(identifier)")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.textSelection(.enabled)
    }
}
