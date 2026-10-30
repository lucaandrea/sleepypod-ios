import Foundation

/// A small, deterministic display model for saved prose. The original response stays untouched.
struct ReportDocument {
    struct Block: Identifiable, Equatable {
        enum Kind: Equatable { case heading(Int), paragraph, bullet(String) }
        let id: Int
        let kind: Kind
        let text: String
        let evidence: [String]
    }
    let blocks: [Block]

    init(text: String, facts: [SleepFact]) {
        let allowed = Set(facts.map(\.id)).intersection(ReportEvidenceLabel.titles.keys)
        var result: [Block] = [], paragraph: [String] = []
        func append(_ text: String, kind: Block.Kind) {
            let body = NSMutableString(string: text)
            var citations: [String] = [], removals: [NSRange] = []
            // Only exact, supplied IDs become source badges. Unknown references remain visible.
            let expression = try? NSRegularExpression(pattern: #"\[([a-z][a-z0-9_.-]*)\](?!\()"#)
            let matches = expression?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
            for match in matches {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let identifier = String(text[range])
                guard allowed.contains(identifier) else { continue }
                if !citations.contains(identifier) { citations.append(identifier) }
                removals.append(match.range)
            }
            // Reverse offsets preserve linked labels and Unicode while removing only citations.
            for range in removals.reversed() { body.deleteCharacters(in: range) }
            result.append(.init(id: result.count, kind: kind, text: (body as String).trimmingCharacters(in: .whitespacesAndNewlines), evidence: citations))
        }
        func flush() {
            guard !paragraph.isEmpty else { return }
            append(paragraph.joined(separator: "\n"), kind: .paragraph); paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            let heading = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(heading), line.dropFirst(heading).first == " " {
                flush(); append(String(line.dropFirst(heading + 1)), kind: .heading(heading)); continue
            }
            if ["- ", "* ", "+ "].contains(where: line.hasPrefix) {
                flush(); append(String(line.dropFirst(2)), kind: .bullet("•")); continue
            }
            let number = line.prefix(while: \.isNumber)
            if !number.isEmpty, line.dropFirst(number.count).hasPrefix(". ") {
                flush(); append(String(line.dropFirst(number.count + 2)), kind: .bullet("\(number).")); continue
            }
            paragraph.append(line)
        }
        flush(); blocks = result
    }

    /// Inline emphasis is rendered without letting a model response create navigable links.
    static func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let links = result.runs.filter { $0.link != nil }.map(\.range)
        for range in links { result[range].link = nil }
        return result
    }
}
