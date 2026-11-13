import XCTest
import UIKit

@MainActor final class MorningBriefUITests: XCTestCase {
    func testThreeTakeawaysComparisonAndGroundedAnswerRemainReadable() {
        review(large: false)
    }
    func testBriefAtMaximumTextSizePreservesEvidenceAndActions() {
        review(large: true)
    }
    func testMissingAndLegacyChartEvidenceRemainDistinct() {
        let empty = launch("empty")
        reveal(empty.staticTexts["brief.chart.empty"], empty); capture("Brief-empty")
        XCTAssertFalse(empty.otherElements["brief.chart"].exists)
        reveal(empty.staticTexts["brief.experiment.unavailable"], empty); capture("Brief-no-experiment")
        empty.terminate()
        let legacy = launch("legacy")
        reveal(legacy.staticTexts["brief.noChart"], legacy); capture("Brief-legacy")
        XCTAssertTrue(legacy.buttons["Full interpretation and evidence"].exists)
    }
    func testExternalSharingLabelAndQuestionKeyboardInSafePractice() {
        let app = launch("complete", external: true)
        let consent = app.switches["brief.consent"]
        reveal(consent, app)
        XCTAssertFalse(consent.isEnabled)
        XCTAssertTrue(consent.label.contains("https://example.invalid"))
        capture("Brief-sharing")
        let field = app.textFields["Your question"].exists ? app.textFields["Your question"] : app.textViews["Your question"]
        reveal(field, app); field.tap(); field.typeText("What can this saved evidence tell me?")
        XCTAssertTrue((field.value as? String ?? "").contains("saved evidence"))
        XCTAssertFalse(app.buttons["brief.ask"].isEnabled)
        capture("Brief-question-keyboard")
        app.terminate()
    }
    private func review(large: Bool) {
        let app = launch(large ? "sparse" : "complete", large: large)
        let prefix = large ? "Brief-large" : "Brief"
        capture(prefix + "-overview")
        for identifier in ["latest", "comparison", "coverage"] {
            let item = app.descendants(matching: .any).matching(identifier: "brief.takeaway.\(identifier)").firstMatch
            reveal(item, app)
            XCTAssertGreaterThanOrEqual(item.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(item.frame.maxX, app.frame.maxX)
            capture(prefix + "-" + identifier)
        }
        let chart = app.descendants(matching: .any).matching(identifier: "brief.chart").firstMatch
        reveal(chart, app); capture(prefix + "-chart")
        let days = app.buttons["brief.days"]
        if large {
            let coverageNotes = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Blank days are unknown")).firstMatch
            revealStart(coverageNotes, app); capture(prefix + "-chart-notes")
            let importNotes = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Health imported")).firstMatch
            revealStart(importNotes, app); capture(prefix + "-chart-import-notes")
        } else {
            reveal(days, app); capture(prefix + "-chart-notes")
        }
        reveal(days, app); days.tap()
        let unknown = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", ", Unknown")).firstMatch
        reveal(unknown, app); capture(prefix + "-days")
        reveal(days, app); days.tap()
        let experiment = app.descendants(matching: .any).matching(identifier: "brief.experiment").firstMatch
        reveal(experiment, app); capture(prefix + "-experiment")
        let full = app.buttons["Full interpretation and evidence"]
        reveal(full, app); full.tap()
        reveal(app.staticTexts["Your recent pattern"], app); capture(prefix + "-interpretation")
        reveal(full, app); full.tap()
        let field = app.textFields["Your question"].exists ? app.textFields["Your question"] : app.textViews["Your question"]
        reveal(field, app); capture(prefix + "-question")
        let ask = app.buttons["brief.ask"]
        reveal(ask, app); XCTAssertFalse(ask.isEnabled)
        let answer = app.staticTexts["Does a longer recording mean I slept better?"]
        reveal(answer, app); capture(prefix + "-answer-question")
        let answerBody = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Not by itself.")).firstMatch
        // The final paragraph can sit near the bottom safe area after scrolling ends.
        reveal(answerBody, app, inset: 60); capture(prefix + "-answer")
        app.terminate()
    }
    private func launch(_ scenario: String, large: Bool = false, external: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--morning-brief-fixture", "-apiBackend", "demo", "-onboardingComplete", "YES",
            "-healthSyncEnabled", "NO", "-household.personalWorkspaceActive", "NO", "-uiBriefScenario", scenario,
            "-intelligence.provider", external ? "ollama" : "apple", "-appearance", large ? "Light" : "Dark"]
        if external { app.launchArguments += ["-intelligence.localAddress", "https://example.invalid"] }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Morning brief"].waitForExistence(timeout: 15))
        return app
    }
    private func revealStart(_ element: XCUIElement, _ app: XCUIApplication) {
        reveal(element, app)
        // Tablet paragraphs already fit; the phone needs its first line below the bar.
        guard app.frame.width < 700 else { return }
        let targetY = app.frame.minY + 160
        for _ in 0..<16 {
            let distance = targetY - element.frame.minY
            if abs(distance) < 24 { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = start.withOffset(CGVector(dx: 0, dy: max(-300, min(300, distance))))
            // Stop the drag before release so momentum cannot repeatedly overshoot the first line.
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTFail("Could not align the beginning of the chart notes")
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, inset: CGFloat = 120) {
        for _ in 0..<45 {
            let viewport = app.frame.insetBy(dx: 0, dy: inset)
            if element.exists, element.frame.height > 0,
               viewport.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)), element.isHittable { return }
            if element.exists, element.frame.midY < viewport.minY { app.swipeDown() } else { app.swipeUp() }
        }
        print(app.debugDescription); capture("Brief-unreachable"); XCTFail("Could not reach \(element)")
    }
    private func capture(_ name: String) {
        // Scroll/declaration layout can settle just after XCTest reports the control hittable.
        // Let the display finish that transition before preserving visual evidence.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
