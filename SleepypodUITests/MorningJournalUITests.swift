import XCTest
import UIKit

@MainActor final class MorningJournalUITests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-healthSyncEnabled", "NO", "-uiRoute", "sleep", "-uiJournalScenario", scenario, "-appearance", UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"]
        app.launch(); XCTAssertTrue(app.buttons["Sleep options"].waitForExistence(timeout: 15)); XCTAssertTrue(app.buttons["Edit times"].waitForExistence(timeout: 10))
        app.buttons["Sleep options"].tap(); if app.buttons["Personal tools"].exists { app.buttons["Personal tools"].tap() }
        let link = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Morning check-in")).firstMatch
        _ = link.waitForExistence(timeout: 3)
        for _ in 0..<8 { if link.exists && link.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(link.isHittable); link.tap(); XCTAssertTrue(app.buttons["journal.reload"].waitForExistence(timeout: 8)); return app
    }
    func testPatternsDraftAcrossSidesHistoricalEntryAndDelete() {
        let app = launch("example"); capture(app, "Journal-entry")
        reveal(app.staticTexts["journal.association.sleepypod.caffeine"], app); capture(app, "Journal-controller-pattern")
        reveal(app.staticTexts["journal.association.free-sleep.caffeine"], app); capture(app, "Journal-imported-pattern")
        let note = app.descendants(matching: .any).matching(identifier: "journal.notes").firstMatch; replaceNote(note, "Retained native journal draft", app)
        reveal(app.segmentedControls["journal.side"], app, searchUp: true); app.segmentedControls["journal.side"].buttons["Right"].tap()
        reveal(note, app, searchUp: true); XCTAssertTrue(["", "Add a private note"].contains(note.value as? String ?? "")); capture(app, "Journal-empty-side")
        reveal(app.segmentedControls["journal.side"], app, searchUp: true); app.segmentedControls["journal.side"].buttons["Left"].tap()
        reveal(note, app, searchUp: true); XCTAssertEqual(note.value as? String, "Retained native journal draft")
        let save = app.buttons["journal.save"]; reveal(save, app); save.tap()
        XCTAssertTrue(app.staticTexts["journal.notice"].waitForExistence(timeout: 5)); capture(app, "Journal-saved")
        let prior = app.buttons["journal.entry.2026-10-18"]; reveal(prior, app); prior.tap()
        reveal(note, app, searchUp: true); XCTAssertTrue(["", "Add a private note"].contains(note.value as? String ?? "")); capture(app, "Journal-imported-entry")
        let deletion = app.buttons["journal.delete"]; reveal(deletion, app); deletion.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Delete check-in", "journal.delete")).firstMatch; XCTAssertTrue(confirm.waitForExistence(timeout: 3)); confirm.tap()
        XCTAssertTrue(app.staticTexts["journal.notice"].waitForExistence(timeout: 5)); XCTAssertFalse(deletion.exists)
        capture(app, "Journal-deleted")
    }
    func testConflictingAndUncertainSavesKeepDraftsAndReadCurrentEntries() {
        let app = launch("conflict"), note = app.descendants(matching: .any).matching(identifier: "journal.notes").firstMatch
        replaceNote(note, "My native conflict draft", app)
        let save = app.buttons["journal.save"]; reveal(save, app); save.tap()
        reveal(app.staticTexts["journal.error"], app, searchUp: true); capture(app, "Journal-conflict")
        let reload = app.buttons["journal.reload"]; reveal(reload, app); reload.tap()
        let keep = app.buttons["journal.keepDraft"]; reveal(keep, app, searchUp: true); capture(app, "Journal-saved-comparison"); keep.tap()
        reveal(note, app, searchUp: true); XCTAssertEqual(note.value as? String, "My native conflict draft")
        reveal(save, app); XCTAssertTrue(save.isEnabled); save.tap(); capture(app, "Journal-conflict-resolved"); app.terminate()
        let lost = launch("lost-save"), lostNote = lost.descendants(matching: .any).matching(identifier: "journal.notes").firstMatch
        replaceNote(lostNote, "Read back my native draft", lost)
        let lostSave = lost.buttons["journal.save"]; reveal(lostSave, lost); lostSave.tap(); XCTAssertFalse(lostSave.isEnabled)
        reveal(lost.staticTexts["journal.error"], lost, searchUp: true); capture(lost, "Journal-uncertain-save")
        let readback = lost.buttons["journal.reload"]; reveal(readback, lost); readback.tap()
        reveal(lost.staticTexts["journal.notice"], lost, searchUp: true); XCTAssertTrue(lost.staticTexts["journal.notice"].label.contains("Nothing was sent again"))
        capture(lost, "Journal-readback"); reveal(lostNote, lost); XCTAssertEqual(lostNote.value as? String, "Read back my native draft")
    }
    func testEmptyAndOfflineRemainDistinct() {
        let empty = launch("empty"); reveal(empty.staticTexts["No check-ins in this window."], empty); capture(empty, "Journal-empty"); empty.terminate()
        let offline = launch("offline"); XCTAssertTrue(offline.staticTexts["journal.error"].waitForExistence(timeout: 5))
        XCTAssertFalse(offline.buttons["journal.save"].exists); capture(offline, "Journal-offline")
    }
    private func replaceNote(_ note: XCUIElement, _ value: String, _ app: XCUIApplication) {
        reveal(note, app, searchUp: true); note.tap()
        let original = (note.value as? String).flatMap { $0 == "Add a private note" ? "" : $0 } ?? ""
        if !original.isEmpty {
            note.press(forDuration: 1.1)
            let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Select All")).firstMatch
            for _ in 0..<5 {
                if selectAll.waitForExistence(timeout: 1) { break }
                let next = app.buttons["Next Page"].firstMatch
                guard next.exists && next.isHittable else { break }
                next.tap()
            }
            XCTAssertTrue(selectAll.exists); selectAll.tap()
        }
        note.typeText(value)
        XCTAssertEqual(note.value as? String, value)
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2), done.isHittable { done.tap() }
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication, searchUp: Bool = false) {
        let scroll = app.scrollViews["journal.scroll"]
        for attempt in 0..<60 {
            let bounds = scroll.frame.intersection(app.frame), top = max(bounds.minY + 12, app.navigationBars.firstMatch.frame.maxY + 12)
            let frame = element.exists ? element.frame : .zero
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top - 24))
            if element.exists, element.isHittable, visible.contains(frame) || (frame.height > visible.height && frame.minY >= visible.minY && visible.intersects(frame)) { return }
            let direction = frame.isEmpty ? (searchUp && attempt < 24 ? -1.0 : 1.0) : (frame.midY >= visible.midY ? 1.0 : -1.0)
            let distance = min(0.45, max(0.08, abs(frame.midY - visible.midY) / max(bounds.height, 1)))
            scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 + direction * distance / 2)).press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: .init(dx: 0.02, dy: 0.5 - direction * distance / 2)))
        }
        XCTFail("Cannot reach \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }
}
