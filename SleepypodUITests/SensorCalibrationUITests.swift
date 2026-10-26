import XCTest
import UIKit

@MainActor final class SensorCalibrationUITests: XCTestCase {
    func testSideSignalsAndNewCalibrationResults() {
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "settings"]
        app.launch()
        let status = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Status,")).firstMatch
        reveal(status, app: app); status.tap()
        reveal(app.buttons["system.calibration"], app: app); app.buttons["system.calibration"].tap()
        XCTAssertTrue(app.navigationBars["Calibration"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["DEMO · simulated calibration and signals"].exists)
        let side = app.buttons["calibration.side"]
        reveal(side, app: app); side.tap()
        let right = app.buttons.matching(NSPredicate(format: "label == %@ OR label ENDSWITH %@", "Right", "· Right")).firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 3)); right.tap()
        capture(app, "Calibration-overview")
        let piezo = app.buttons["calibration.trigger.piezo"]
        reveal(piezo, app: app)
        XCTAssertTrue(piezo.isEnabled)
        piezo.tap()
        let start = app.buttons["Start calibration"]
        XCTAssertTrue(start.waitForExistence(timeout: 3)); start.tap()
        let notice = app.staticTexts["calibration.notice"]
        reveal(notice, app: app)
        waitForNewResult(notice)
        capture(app, "Calibration-new-result")
        let inspect = app.sliders["Inspect piezo signal"]
        reveal(inspect, app: app)
        XCTAssertTrue(inspect.exists)
        inspect.adjust(toNormalizedSliderPosition: 0.9)
        reveal(app.staticTexts["calibration.signalReadout.piezo"], app: app)
        capture(app, "Calibration-piezo-inspection")
        let cap = app.sliders["Inspect capacitance signal"]
        reveal(cap, app: app); cap.adjust(toNormalizedSliderPosition: 1)
        reveal(app.staticTexts["calibration.signalReadout.capacitance"], app: app)
        capture(app, "Calibration-capacitance")
        let temperature = app.sliders["Inspect temperature signal"]
        reveal(temperature, app: app); temperature.adjust(toNormalizedSliderPosition: 1)
        reveal(app.staticTexts["calibration.signalReadout.temperature"], app: app)
        capture(app, "Calibration-temperature")
        let all = app.buttons["calibration.all"]
        reveal(all, app: app)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: all)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 0.5)
        all.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 3)); start.tap()
        reveal(notice, app: app)
        waitForNewResult(notice)
    }
    private func waitForNewResult(_ notice: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "New calibration results received."), object: notice)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<70 {
            let content = app.scrollViews["calibration.content"]
            let surface = content.exists ? content : app
            let visible = surface.frame.intersection(app.frame).insetBy(dx: 0, dy: 50)
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let down = element.exists && element.frame.midY < visible.minY
            let distance = min(200, visible.height * 0.35)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY))
            let end = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY + (down ? distance : -distance)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
