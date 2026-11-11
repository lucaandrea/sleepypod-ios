import XCTest

@MainActor final class MorningJournalContextUITests: XCTestCase {
    func testDetailedContextSavingAndComparisonCounts() {
        let app = launch("context")
        for label in ["Caffeine", "Alcohol", "Exercise", "Restfulness", "Temperature comfort", "Pattern window"] {
            XCTAssertTrue(app.staticTexts[label].exists, "Missing persistent field label: \(label)")
        }
        capture(app, "Context-journal-overview")
        let amount = app.textFields["journal.context.caffeine.amount"]
        reveal(amount, app)
        XCTAssertEqual(amount.value as? String, "200.0")
        replaceAmount(amount, with: "175", app)
        capture(app, "Context-journal-habits")
        let alcohol = app.buttons["journal.context.alcohol.status"]
        reveal(alcohol, app)
        XCTAssertTrue(alcohol.label.contains("Not logged"))
        alcohol.tap(); app.buttons["None"].firstMatch.tap()
        let save = app.buttons["journal.save"]; reveal(save, app); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["journal.notice"].waitForExistence(timeout: 5))
        capture(app, "Context-journal-saved")
        reveal(amount, app, searchUp: true); XCTAssertEqual(amount.value as? String, "175.0")
        app.terminate()
        let patterns = launch("context")
        let comparison = patterns.descendants(matching: .any).matching(identifier: "journal.context.comparison.exercise-time").firstMatch
        reveal(comparison, patterns)
        XCTAssertTrue(patterns.staticTexts["Within 3 hours: too warm on 5 of 5 dates."].exists)
        capture(patterns, "Context-journal-patterns")
        verifyDefinitions(patterns, large: false)
    }
    func testTimeZoneConflictAndSavedDraftChoice() {
        let app = launch("context-zone")
        let caffeine = app.buttons["journal.context.caffeine.status"]
        reveal(caffeine, app); caffeine.tap(); app.buttons["Yes"].firstMatch.tap()
        let add = app.buttons["journal.context.caffeine.add"]; reveal(add, app); add.tap()
        let clock = app.descendants(matching: .any).matching(identifier: "journal.context.caffeine.clock").firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 4)); capture(app, "Context-journal-clock")
        let save = app.buttons["journal.save"]; reveal(save, app); save.tap()
        XCTAssertTrue(app.staticTexts["journal.error"].waitForExistence(timeout: 5))
        let reload = app.buttons["journal.reload"]; reveal(reload, app); reload.tap()
        let conflict = app.staticTexts["journal.context.zoneConflict"]; reveal(conflict, app, searchUp: true)
        XCTAssertTrue(conflict.label.contains("America/New_York")); capture(app, "Context-journal-zone-conflict")
        let keep = app.buttons["journal.keepDraft"]; reveal(keep, app); XCTAssertEqual(keep.label, "Keep draft in new time zone"); keep.tap()
        reveal(save, app); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["journal.notice"].waitForExistence(timeout: 5)); capture(app, "Context-journal-zone-saved")
    }
    func testContextRemainsReadableAtMaximumTextSize() {
        let app = launch("context", large: true)
        capture(app, "Context-journal-large-overview")
        let amount = app.textFields["journal.context.caffeine.amount"]; reveal(amount, app)
        capture(app, "Context-journal-large-habits")
        let details = app.staticTexts["journal.context.details"]
        reveal(details, app); details.tap()
        let clock = app.descendants(matching: .any).matching(identifier: "journal.context.bedtime.clock").firstMatch; reveal(clock, app)
        capture(app, "Context-journal-large-clock")
        let stress = app.buttons["journal.context.stress"]; reveal(stress, app); capture(app, "Context-journal-large-stress")
        let save = app.buttons["journal.save"]; reveal(save, app)
        XCTAssertGreaterThanOrEqual(save.frame.height, 44); capture(app, "Context-journal-large-save")
        let comparison = app.staticTexts["journal.context.comparison.exercise-time"]
        reveal(comparison, app); capture(app, "Context-journal-large-comparison")
        let counts = app.staticTexts["Within 3 hours: too warm on 5 of 5 dates."]
        reveal(counts, app); capture(app, "Context-journal-large-comparison-counts")
        verifyDefinitions(app, large: true)
    }
    func testRepeatedClockOccurrenceCanBeReviewedAndSaved() {
        for large in [false, true] {
            let app = launch("context-fold", large: large)
            let occurrence = app.buttons["journal.context.caffeine.occurrence"]
            reveal(occurrence, app); XCTAssertTrue(occurrence.label.contains("Earlier occurrence"))
            occurrence.tap(); app.buttons["Later occurrence"].firstMatch.tap()
            XCTAssertTrue(occurrence.label.contains("Later occurrence"))
            capture(app, "Context-journal-fold-\(large)")
            let save = app.buttons["journal.save"]; reveal(save, app); XCTAssertTrue(save.isEnabled); save.tap()
            XCTAssertTrue(app.staticTexts["journal.notice"].waitForExistence(timeout: 5))
            reveal(occurrence, app, searchUp: true); XCTAssertTrue(occurrence.label.contains("Later occurrence"))
            app.terminate()
        }
    }
    func testInvalidAmountAndCompleteSavedContextConflict() {
        let app = launch("context-conflict", light: true)
        let amount = app.textFields["journal.context.caffeine.amount"]
        reveal(amount, app); replaceAmount(amount, with: "-1", app)
        let issue = app.staticTexts["journal.context.error"]
        reveal(issue, app)
        XCTAssertTrue(issue.label.contains("nonnegative"))
        capture(app, "Context-journal-light-validation")
        let save = app.buttons["journal.save"]; reveal(save, app); XCTAssertFalse(save.isEnabled)
        reveal(amount, app, searchUp: true); replaceAmount(amount, with: "175", app)
        reveal(save, app); XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["journal.error"].waitForExistence(timeout: 5))
        let reload = app.buttons["journal.reload"]; reveal(reload, app); reload.tap()
        let caffeine = app.staticTexts["journal.saved.caffeine.status"]
        reveal(caffeine, app, searchUp: true); XCTAssertEqual(caffeine.label, "Caffeine: Not logged")
        let alcohol = app.staticTexts["journal.saved.alcohol.amount"]
        reveal(alcohol, app); XCTAssertEqual(alcohol.label, "0 US standard drinks")
        capture(app, "Context-journal-saved-context-habits")
        let exercise = app.staticTexts["journal.saved.exercise.amount"]
        reveal(exercise, app); XCTAssertEqual(exercise.label, "42 minutes")
        let stress = app.staticTexts["journal.saved.stress"]
        reveal(stress, app); XCTAssertEqual(stress.label, "Stress: Higher")
        XCTAssertTrue(app.staticTexts["journal.saved.bedtime"].exists)
        XCTAssertTrue(app.staticTexts["journal.saved.meal"].exists)
        capture(app, "Context-journal-saved-context-clocks")
        let useSaved = app.buttons["journal.useSaved"]; reveal(useSaved, app); useSaved.tap()
        let savedCaffeine = app.buttons["journal.context.caffeine.status"]
        reveal(savedCaffeine, app); XCTAssertTrue(savedCaffeine.label.contains("Not logged"))
    }
    private func replaceAmount(_ amount: XCUIElement, with text: String, _ app: XCUIApplication) {
        amount.tap(); amount.doubleTap()
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 1) { selectAll.tap() }
        else {
            let value = amount.value as? String ?? ""
            amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        amount.typeText(text)
        app.buttons["Done"].firstMatch.tap()
    }
    private func verifyDefinitions(_ app: XCUIApplication, large: Bool) {
        let disclosure = app.staticTexts["journal.context.definitions"]
        reveal(disclosure, app); disclosure.tap()
        let counts = app.staticTexts["journal.context.definition.exercise-time"]
        reveal(counts, app); XCTAssertTrue(counts.label.contains("Excluded: 0"))
        capture(app, "Context-journal-definitions-\(large)")
    }
    private func launch(_ scenario: String, large: Bool = false, light: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--journal-context-fixture", "-apiBackend", "demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO",
            "-uiJournalScenario", scenario, "-appearance", large || light ? "Light" : "Dark"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.buttons["journal.reload"].waitForExistence(timeout: 10)); return app
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, searchUp: Bool = false) {
        let scroll = app.scrollViews["journal.scroll"]
        for attempt in 0..<55 {
            let bounds = scroll.frame.intersection(app.frame)
            let top = max(bounds.minY + 12, app.navigationBars.firstMatch.frame.maxY + 12)
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 24))
            let frame = element.exists ? element.frame : .zero
            if element.exists, element.isHittable, visible.contains(frame) || (frame.height > visible.height && frame.minY >= visible.minY && visible.intersects(frame)) { return }
            let direction = frame.isEmpty ? (searchUp && attempt < 24 ? -1.0 : 1.0) : (frame.midY >= visible.midY ? 1.0 : -1.0)
            let distance = min(0.45, max(0.08, abs(frame.midY - visible.midY) / max(bounds.height, 1)))
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05,
                thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 - direction * distance / 2)))
        }
        capture(app, "Context-journal-unreachable"); print(app.debugDescription)
        XCTFail("Cannot reach requested journal control")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
