import XCTest
import UIKit

@MainActor final class SensorDiagnosticsUITests: XCTestCase {
    func testSensorLayersReplayAndHistoryRanges() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let appearance = UIDevice.current.userInterfaceIdiom == .pad ? "Light" : "Dark"
        app.launchArguments = ["-apiBackend", "demo", "--demo", "-onboardingComplete", "YES", "-appearance", appearance, "-healthSyncEnabled", "NO", "-uiRoute", "settings"]
        app.launch()
        let sensors = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Sensors")).firstMatch
        reveal(sensors, app: app); sensors.tap()
        XCTAssertTrue(app.navigationBars["Sensors"].waitForExistence(timeout: 5))
        let toggle = app.buttons["sensors.streamToggle"]
        reveal(toggle, app: app); toggle.tap()
        XCTAssertTrue(app.staticTexts["Paused"].waitForExistence(timeout: 3))
        capture(app, "Sensors-paused")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5))
        capture(app, "Sensors-thermal")
        let layer = app.buttons["sensors.matrixLayer"]
        reveal(layer, app: app); layer.tap(); app.buttons["Capacitance"].firstMatch.tap()
        reveal(app.staticTexts["Channel pair 1"], app: app)
        capture(app, "Sensors-matrix")
        let presence = app.staticTexts["sensors.presence.left"]
        reveal(presence, app: app)
        let occupied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "In bed"), object: presence)
        XCTAssertEqual(XCTWaiter.wait(for: [occupied], timeout: 5), .completed)
        capture(app, "Sensors-presence")
        reveal(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Heatsink")).firstMatch, app: app)
        capture(app, "Sensors-freezer")
        let channel = app.switches["sensors.waveformRight"]
        reveal(channel, app: app); channel.tap(); XCTAssertEqual(channel.value as? String, "0")
        channel.tap(); XCTAssertEqual(channel.value as? String, "1")
        let replay = app.buttons["sensors.waveformReplay"]
        reveal(replay, app: app); replay.tap()
        let inspect = app.sliders["sensors.waveformInspection"]
        reveal(inspect, app: app); inspect.adjust(toNormalizedSliderPosition: 0.4)
        capture(app, "Sensors-replay")
        let live = app.buttons["sensors.waveformLive"]
        reveal(live, app: app); live.tap()
        XCTAssertFalse(app.sliders["sensors.waveformInspection"].exists)
        let history = app.buttons["sensors.historyRange"]
        reveal(history, app: app); history.tap(); app.buttons["24 hours"].firstMatch.tap()
        capture(app, "Sensors-history")
        reveal(app.staticTexts["HUMIDITY · 24H"], app: app)
        capture(app, "Sensors-humidity")
        let mode = app.segmentedControls["sensors.flowMode"]
        reveal(mode, app: app); mode.buttons["RPM"].tap()
        let range = app.buttons["sensors.flowRange"]
        reveal(range, app: app); range.tap(); app.buttons["7 days"].firstMatch.tap()
        capture(app, "Sensors-flow")
        let console = app.buttons["sensors.console"]
        reveal(console, app: app); console.tap()
        XCTAssertTrue(app.navigationBars["Sensor console"].waitForExistence(timeout: 3))
        let consoleMode = app.segmentedControls["sensors.consoleMode"]
        let consoleMenu = app.buttons["sensors.consoleModeMenu"]
        if consoleMenu.exists {
            consoleMenu.tap(); app.buttons["Frames"].firstMatch.tap()
            XCTAssertTrue(consoleMenu.label.contains("Frames"))
        } else {
            consoleMode.buttons["Frames"].tap()
            XCTAssertTrue(consoleMode.buttons["Frames"].isSelected)
        }
        app.buttons["sensors.consolePause"].tap()
        capture(app, "Sensors-console")
        let frame = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sensors.rawFrame.")).firstMatch
        if !frame.isHittable { app.swipeUp(velocity: .slow) }
        let frameType = frame.identifier.replacingOccurrences(of: "sensors.rawFrame.", with: "")
        frame.tap()
        XCTAssertTrue(app.navigationBars[frameType].waitForExistence(timeout: 3))
        capture(app, "Sensors-raw-frame")
        app.navigationBars[frameType].buttons["Done"].tap()
        app.navigationBars["Sensor console"].buttons["Done"].tap()
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<35 {
            let content = app.scrollViews["sensors.content"]
            let surface = content.exists ? content : app
            let visible = surface.frame.intersection(app.frame)
            if element.exists, element.isHittable, visible.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            let down = element.exists && element.frame.midY < visible.minY
            // Scroll at the edge so the rotatable bed and waveform sliders keep their own gestures.
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: down ? 0.28 : 0.78))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: down ? 0.78 : 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not reveal \(element.identifier)")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
