import XCTest
@testable import FreeSleepKit

final class ReportDocumentTests: XCTestCase {
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
