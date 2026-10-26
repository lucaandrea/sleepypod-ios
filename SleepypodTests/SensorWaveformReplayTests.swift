import XCTest
@testable import Sleepypod

final class SensorWaveformReplayTests: XCTestCase {
    func testSupersededRequestsAndGoLiveIgnoreLateReplay() {
        var replay = SensorWaveformReplay()
        replay.setRange(.init(min: 100, max: 500))
        let first = replay.begin(at: 120)!, second = replay.begin(at: 130)!
        let frame = PiezoDualFrame(ts: 130, freq: 500, left1: [1, 2], right1: [3, 4])
        replay.accept(.init(type: "waveform", requestId: first, frames: [frame]))
        XCTAssertTrue(replay.loading)
        XCTAssertEqual(replay.frames?.count, 0)
        replay.accept(.init(type: "waveform", requestId: second, frames: [frame]))
        XCTAssertFalse(replay.loading)
        XCTAssertEqual(replay.frames?.count, 1)
        replay.goLive()
        replay.accept(.init(type: "waveform", requestId: second, frames: [frame]))
        XCTAssertNil(replay.frames)
    }
    func testRangeAndTimeoutValidation() {
        var replay = SensorWaveformReplay()
        replay.setRange(.init(min: 0, max: 0)); XCTAssertNil(replay.range)
        replay.setRange(.init(min: 100, max: 200))
        XCTAssertNil(replay.begin(at: .nan)); XCTAssertNil(replay.begin(at: 250))
        let request = replay.begin(at: 150)!
        replay.fail("Timed out", request: request - 1); XCTAssertTrue(replay.loading)
        replay.fail("Timed out", request: request); XCTAssertFalse(replay.loading)
        XCTAssertEqual(replay.error, "Timed out")
    }
    func testSampleTimesPreserveGapsAndRateChanges() {
        let frames: [PiezoDualFrame] = [
            .init(ts: 100, freq: 2, left1: [1, 2], right1: [3, 4]),
            .init(ts: 101, freq: 2, left1: [5, 6], right1: [7, 8]),
            .init(ts: 103, freq: 2, left1: [9, 10], right1: [11, 12]),
            .init(ts: 104, freq: 4, left1: [13, 14], right1: [])
        ]
        let points = SensorWaveformSample.points(frames: frames, sides: [.left])
        XCTAssertEqual(points.map(\.time), [100, 100.5, 101, 101.5, 103, 103.5, 104, 104.25])
        XCTAssertEqual(points.map(\.segment), [1, 1, 1, 1, 2, 2, 3, 3])
    }
    @MainActor func testReplayResponseNeverReplacesLiveSensorState() {
        let stream = SensorStreamService()
        stream.waveformReplay.setRange(.init(min: 100, max: 500))
        let request = stream.waveformReplay.begin(at: 150)!
        stream.handleFrame(Data("{\"type\":\"waveform\",\"requestId\":\(request),\"frames\":[{\"type\":\"piezo-dual\",\"ts\":150,\"freq\":500,\"left1\":[1],\"right1\":[2]}]}".utf8))
        XCTAssertEqual(stream.waveformReplay.frames?.count, 1)
        XCTAssertTrue(stream.piezoLeft.isEmpty)
        XCTAssertNil(stream.lastSensorTime)
        XCTAssertNil(stream.vitalsUpdatedAt)
    }
}
