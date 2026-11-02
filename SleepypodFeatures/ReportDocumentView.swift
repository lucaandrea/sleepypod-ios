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
                    case .quote:
                        Text(ReportDocument.inline(block.text)).font(.body).foregroundStyle(Theme.text2)
                            .padding(.leading, 12)
                    case .code:
                        ScrollView(.horizontal) {
                            Text(block.text).font(.system(.body, design: .monospaced)).padding(12)
                        }
                    case .table:
                        ScrollView(.horizontal) {
                            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                                // A report is an immutable snapshot; row and column positions are stable.
                                ForEach(Array(block.cells.enumerated()), id: \.offset) { rowIndex, cells in
                                    GridRow {
                                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                            Text(ReportDocument.inline(cell)).font(rowIndex == 0 ? .headline : .body)
                                        }
                                    }
                                }
                            }.padding(12)
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
