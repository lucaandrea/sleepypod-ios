import XCTest
@testable import FreeSleepKit

final class ReportDocumentTests: XCTestCase {
    func testExperimentRetainsTheActualSuggestionAndItsEvaluationEvidence() throws {
        let text = "### Summary\nPrior observation.\n### One experiment to consider\nTry one routine change. [health.recent]\n#### Evaluate\nCompare your comfort notes.\n### Uncertainty\nKeep this in the original report."
        let document = ReportDocument(text: text, facts: [.init(id: "health.recent", text: "Three recorded days")])
        let experiment = try XCTUnwrap(document.experiment)
        XCTAssertEqual(experiment.blocks.map(\.text), ["Try one routine change.", "Evaluate", "Compare your comfort notes."])
        XCTAssertEqual(experiment.blocks.first?.evidence, ["health.recent"])
        XCTAssertTrue(document.blocks.contains { $0.text == "Keep this in the original report." })
    }
    func testExperimentRequiresAnUnambiguousExplicitSection() {
        for text in [
            "Try changing your bedtime.",
            "### Optional experiments\nOne. Two.",
            "### One optional experiment\n### Uncertainty\nUnknown.",
            "### One optional experiment\nFirst.\n### One experiment to consider\nSecond.",
            "```\n### One optional experiment\nThis is a literal example.\n```"
        ] { XCTAssertNil(ReportDocument(text: text, facts: []).experiment) }
        let legacy = ReportDocument(text: "### One optional experiment\n1. Keep a consistent routine.\n2. Compare three mornings.", facts: [])
        XCTAssertEqual(legacy.experiment?.blocks.count, 2)
    }
    func testAnOversizedProposalIsNeverTruncatedIntoADifferentRecommendation() {
        let text = "### One experiment to consider\n" + String(repeating: "A condition. ", count: 110)
        let document = ReportDocument(text: text, facts: [])
        XCTAssertNil(document.experiment)
        XCTAssertTrue(document.blocks.last!.text.hasSuffix("A condition."))
    }
    func testTablesAndCodeAreStructuredAndNeverCitationBadges() {
        let document = ReportDocument(text: "| Metric | Value |\n| --- | ---: |\n| Sleep | 7h |\n\n```\n# literal\n[health.sleep]\n```", facts: [.init(id: "health.sleep", text: "Seven hours")])
        XCTAssertEqual(document.blocks.map(\.kind), [.table, .code])
        XCTAssertEqual(document.blocks[0].cells, [["Metric", "Value"], ["Sleep", "7h"]])
        XCTAssertEqual(document.blocks[1].text, "# literal\n[health.sleep]")
        XCTAssertTrue(document.blocks[1].evidence.isEmpty)
    }
    func testUnclosedCodeAndQuotesKeepContent() {
        let document = ReportDocument(text: "> A measured observation\n\n```swift\nlet value = 1", facts: [])
        XCTAssertEqual(document.blocks.map(\.kind), [.quote, .code])
        XCTAssertEqual(document.blocks.last?.text, "let value = 1")
    }
    func testHeadingsListsEmphasisAndOrder() {
        let document = ReportDocument(text: "### Summary\n**Recorded** observations.\n\n- First\n2. Second", facts: [])
        XCTAssertEqual(document.blocks.map(\.kind), [.heading(3), .paragraph, .bullet("•"), .bullet("2.")])
        XCTAssertEqual(document.blocks.map(\.text), ["Summary", "**Recorded** observations.", "First", "Second"])
        let formatted = ReportDocument.inline(document.blocks[1].text)
        XCTAssertEqual(String(formatted.characters), "Recorded observations.")
        XCTAssertTrue(formatted.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }
    func testOnlySuppliedKnownEvidenceBecomesBadges() {
        let document = ReportDocument(text: "Read [health.recent], [pod.coverage], [future.metric] and [health.recent].",
                                      facts: [.init(id: "health.recent", text: "Three days"), .init(id: "future.metric", text: "Unrecognized")])
        XCTAssertEqual(document.blocks.first?.evidence, ["health.recent"])
        XCTAssertTrue(document.blocks.first!.text.contains("[pod.coverage]"))
        XCTAssertTrue(document.blocks.first!.text.contains("[future.metric]"))
        let linked = ReportDocument(text: "[health.recent](https://example.invalid)", facts: [.init(id: "health.recent", text: "Three days")])
        XCTAssertTrue(linked.blocks[0].evidence.isEmpty)
        let mixed = ReportDocument(text: "🌙 [health.recent] and [health.recent](https://example.invalid)", facts: [.init(id: "health.recent", text: "Three days")])
        XCTAssertEqual(mixed.blocks[0].text, "🌙  and [health.recent](https://example.invalid)")
        XCTAssertEqual(mixed.blocks[0].evidence, ["health.recent"])
    }
    func testLinksAreInertAndPlainTextRemainsReadable() {
        let text = ReportDocument.inline("See [example](https://example.invalid) and **bold**.")
        XCTAssertFalse(text.runs.contains { $0.link != nil })
        XCTAssertEqual(String(text.characters), "See example and bold.")
        XCTAssertTrue(ReportDocument(text: "\n\n", facts: []).blocks.isEmpty)
        XCTAssertEqual(ReportDocument(text: "Line one\nLine two", facts: []).blocks.first?.text, "Line one\nLine two")
    }
    func testEvidenceNamesPreserveMeasurementMeaning() {
        XCTAssertEqual(ReportEvidenceLabel.title("pod.presence"), "Bed presence")
        XCTAssertEqual(ReportEvidenceLabel.title("health.hrv"), "Daily HRV · SDNN")
        XCTAssertEqual(ReportEvidenceLabel.title("future.temperature"), "future.temperature")
    }
}
