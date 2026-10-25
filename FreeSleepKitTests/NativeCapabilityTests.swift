import Foundation
import XCTest
@testable import FreeSleepKit

final class NativeCapabilityTests: XCTestCase {
    func testEditorsRequireAnImplementedReadyContract() throws {
        for (path, implemented, runtime, version, expected) in [
            ("/api/native/v1", true, "ready", 1, true),
            ("/api/native/v1", false, "ready", 1, false),
            ("/api/native/v1", true, "not_ready", 1, false),
            ("/api/native/v1", true, "unknown", 1, false),
            ("/api/native/v2", true, "ready", 1, false),
            ("https://other.example/api/native/v1", true, "ready", 1, false),
            ("/api/native/v1", true, "ready", 2, false)
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["apiVersion": version,
                "endpoints": ["nativeCompatibility": path],
                "features": ["nativeCompatibility": ["implemented": implemented, "runtime": runtime]]])
            let value = try JSONDecoder().decode(NativeCapabilities.self, from: data)
            XCTAssertEqual(value.supportsNative, expected)
        }
    }
    func testCurrentCoreDoesNotExposeEditorsForAbsentCompatibilityAPI() throws {
        let data = Data(#"{"apiVersion":1,"endpoints":{"nativeCompatibility":null},"features":{"nativeCompatibility":{"implemented":false,"runtime":"not_ready"}}}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(NativeCapabilities.self, from: data).supportsNative)
    }
}
