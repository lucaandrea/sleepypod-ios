import SceneKit
import XCTest
@testable import Sleepypod

@MainActor final class TemperatureInteractionTests: XCTestCase {
    func testPrimeCompletionRejectsFutureInvalidAndExpiredTimes() {
        let now = Date(timeIntervalSince1970: 1793000000)
        for timestamp in [1793000000.0, 1792999999, 1792996401, 1793000000000] {
            XCTAssertTrue(PrimeCompletion(timestamp: timestamp).isRecent(now: now))
        }
        for timestamp in [Double.nan, .infinity, 1793000001, 1792996400, 1793000001000] {
            XCTAssertFalse(PrimeCompletion(timestamp: timestamp).isRecent(now: now))
        }
    }

    func testThermalCameraAccessibilityActionsRotateZoomClampAndReset() throws {
        let scene = ThermalBedSceneView.Coordinator(), view = SCNView()
        scene.installGestures(on: view)
        scene.configure(interactive: true, selectedSide: .left, autoReturn: false, reset: 0, onSelect: nil)
        XCTAssertEqual(view.accessibilityCustomActions?.map(\.name), ["Rotate left", "Rotate right", "Zoom in", "Zoom out", "Reset view"])
        XCTAssertTrue(view.isAccessibilityElement)
        let original = scene.camera.position
        XCTAssertTrue(scene.rotateLeft()); XCTAssertNotEqual(scene.camera.position.x, original.x)
        XCTAssertTrue(scene.rotateRight()); XCTAssertEqual(scene.camera.position.x, original.x, accuracy: 0.001)
        XCTAssertTrue(scene.zoomIn()); XCTAssertLessThan(length(scene.camera.position), length(original))
        for _ in 0..<30 { _ = scene.zoomIn() }
        XCTAssertEqual(length(scene.camera.position), 4.4, accuracy: 0.001)
        for _ in 0..<30 { _ = scene.zoomOut() }
        XCTAssertEqual(length(scene.camera.position), 8, accuracy: 0.001)
        XCTAssertTrue(view.accessibilityValue?.contains("73 percent") == true)
        XCTAssertTrue(scene.resetView()); XCTAssertEqual(length(scene.camera.position), 5.8, accuracy: 0.001)
        XCTAssertEqual(scene.camera.position.x, original.x, accuracy: 0.001)
        scene.configure(interactive: false, selectedSide: nil, autoReturn: false, reset: 0, onSelect: nil)
        XCTAssertFalse(view.isAccessibilityElement); XCTAssertNil(view.accessibilityCustomActions)
    }

    func testBaseVoiceOverCameraActionsRemainReversible() {
        let scene = PositionBedScene.Coordinator(), original = scene.camera.position
        XCTAssertTrue(scene.rotateLeft()); XCTAssertNotEqual(scene.camera.position.x, original.x)
        XCTAssertTrue(scene.rotateRight()); XCTAssertEqual(scene.camera.position.x, original.x, accuracy: 0.001)
        XCTAssertTrue(scene.zoomIn()); XCTAssertEqual(scene.camera.camera?.orthographicScale ?? 0, 1.35, accuracy: 0.001)
        XCTAssertTrue(scene.zoomOut()); XCTAssertEqual(scene.camera.camera?.orthographicScale ?? 0, 1.55, accuracy: 0.001)
        XCTAssertTrue(scene.rotateRight()); XCTAssertTrue(scene.resetView())
        XCTAssertEqual(scene.camera.position.x, original.x, accuracy: 0.001)
    }

    func testBedCamerasRestoreOrientationAfterRepeatedOrbits() {
        let thermal = ThermalBedSceneView.Coordinator(), base = PositionBedScene.Coordinator()
        let thermalOrientation = thermal.camera.simdOrientation, baseOrientation = base.camera.simdOrientation
        for _ in 0..<9 { _ = thermal.rotateRight(); _ = base.rotateRight() }
        _ = thermal.resetView(); _ = base.resetView()
        XCTAssertEqual(abs(simd_dot(thermal.camera.simdOrientation.vector, thermalOrientation.vector)), 1, accuracy: 0.0001)
        XCTAssertEqual(abs(simd_dot(base.camera.simdOrientation.vector, baseOrientation.vector)), 1, accuracy: 0.0001)
    }

    private func length(_ vector: SCNVector3) -> Float { sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z) }
}
