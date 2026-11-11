import XCTest

@MainActor final class PersonalJournalPatternsUITests: XCTestCase {
    private func launch(_ mode: String = "patterns-ready", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--personal-journal-fixture", mode, "--demo", "-apiBackend", "demo", "-healthSyncEnabled", "NO", "-appearance", large ? "Dark" : "Light"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); XCTAssertTrue(app.staticTexts["household.assignment"].waitForExistence(timeout: 20))
        let link = app.buttons["personalJournal.accountLink"]; reveal(link, in: app); link.tap()
        XCTAssertTrue(app.navigationBars["Morning check-in"].waitForExistence(timeout: 10))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        func visible() -> Bool { element.exists && element.isHittable && element.frame.midY > app.frame.minY + 110 && element.frame.midY < app.frame.maxY - 40 }
        for _ in 0..<40 {
            if visible() { break }
            let upward = element.exists ? element.frame.midY > app.frame.maxY - 40 : !towardTop
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.78 : 0.28))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: upward ? 0.28 : 0.78)))
        }
        XCTAssertTrue(visible(), "Unreachable \(element.identifier)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, app.frame.minX); XCTAssertLessThanOrEqual(element.frame.maxX, app.frame.maxX)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func compare(_ app: XCUIApplication) {
        let disclosure = app.buttons["personalPatterns.open"]; reveal(disclosure, in: app); disclosure.tap()
        let compare = app.buttons["personalPatterns.compare"]; reveal(compare, in: app)
        XCTAssertTrue(compare.isEnabled); capture("Patterns-range"); compare.tap()
    }
    func testSavedComparisonsShowCountsAndDefinitionsWithoutSavingDraft() {
        let app = launch()
        let rating = app.buttons["personalJournal.restfulness"]; reveal(rating, in: app); rating.tap()
        app.buttons["5 — Very rested"].tap()
        compare(app)
        let source = app.staticTexts["personalPatterns.source"]; reveal(source, in: app); XCTAssertTrue(source.label.contains("Saved check-ins"))
        let finding = app.staticTexts["personalPatterns.finding.caffeine-time"]; reveal(finding, in: app); capture("Patterns-ready-light")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "too warm on 5 of 5 dates")).firstMatch.exists)
        let definitions = app.buttons["personalPatterns.definitions"]; reveal(definitions, in: app); definitions.tap()
        let missing = app.staticTexts["personalPatterns.definition.alcohol-time"]; reveal(missing, in: app)
        XCTAssertTrue(missing.label.contains("Excluded: 10")); capture("Patterns-definitions-light")
        let note = app.staticTexts["personalPatterns.note"]; reveal(note, in: app)
        XCTAssertTrue(note.label.contains("not statistical validation")); capture("Patterns-interpretation-light")
        let disclosure = app.buttons["personalPatterns.open"]; reveal(disclosure, in: app, towardTop: true); disclosure.tap()
        XCTAssertFalse(source.exists)
        let state = app.staticTexts["personalJournal.savedState"]; reveal(state, in: app, towardTop: true)
        XCTAssertTrue(state.label.contains("Unsaved changes")); app.terminate()
    }
    func testEmptyInsufficientAndFailedReadHaveDistinctRecovery() {
        for mode in ["patterns-empty", "patterns-insufficient", "patterns-error"] {
            let app = launch(mode); compare(app)
            let identifier = mode == "patterns-empty" ? "empty" : mode == "patterns-insufficient" ? "insufficient" : "error"
            let status = app.staticTexts["personalPatterns.\(identifier)"]; reveal(status, in: app)
            XCTAssertFalse(app.staticTexts["personalPatterns.finding.caffeine-time"].exists)
            capture(mode)
            let compare = app.buttons["personalPatterns.compare"]; reveal(compare, in: app, towardTop: true); XCTAssertTrue(compare.isEnabled)
            app.terminate()
        }
    }
    func testLargestTextDarkAndTabletLandscapeKeepFindingsReachable() {
        let app = launch(large: true); compare(app)
        let source = app.staticTexts["personalPatterns.source"]; reveal(source, in: app); capture("Patterns-source-dark-largest-text")
        let finding = app.staticTexts["personalPatterns.finding.caffeine-time"]; reveal(finding, in: app); capture("Patterns-finding-dark-largest-text")
        let definitions = app.buttons["personalPatterns.definitions"]; reveal(definitions, in: app); definitions.tap()
        let caveat = app.staticTexts["personalPatterns.caveat.caffeine-amount"]; reveal(caveat, in: app, towardTop: true)
        XCTAssertTrue(caveat.label.hasSuffix("Association only.")); capture("Patterns-expanded-caveat-dark-largest-text")
        let firstCount = app.staticTexts["personalPatterns.withoutCount.caffeine-time"]; reveal(firstCount, in: app, towardTop: true)
        XCTAssertTrue(firstCount.label.hasSuffix("0 of 5 dates.")); capture("Patterns-expanded-groups-dark-largest-text")
        let counts = app.staticTexts["personalPatterns.definition.exercise-time"]; reveal(counts, in: app); capture("Patterns-counts-dark-largest-text")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            reveal(counts, in: app); XCTAssertGreaterThan(app.frame.width, app.frame.height); capture("Patterns-tablet-landscape")
            XCUIDevice.shared.orientation = .portrait
        }
        app.terminate()
    }
    func testLoadingAndBackgroundNeverRestorePrivateFindings() {
        let app = launch("patterns-loading"); compare(app)
        let progress = app.activityIndicators["personalPatterns.loading"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3)); capture("Patterns-loading")
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertFalse(app.navigationBars["Morning check-in"].exists)
        XCTAssertFalse(app.staticTexts["personalPatterns.source"].exists); app.terminate()
    }
}
