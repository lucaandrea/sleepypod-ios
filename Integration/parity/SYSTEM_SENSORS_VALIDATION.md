# Native Sensors parity

Status: implemented and locally validated; publication checks pending. This milestone does not complete the wider parity audit or release the app.

## Source audit

Compared Core `SensorsScreen.tsx`, `BedTempMatrix.tsx`, `PresenceCard.tsx`, `FreezerHealthCard.tsx`, `FlowrateChart.tsx`, `PiezoWaveform.tsx`, `useSensorStream.ts`, `streaming/normalizeFrame.ts`, and the biometrics/environment/water-level routers. System's Sensors tab is the same native Sensors route already offered in Settings; it now also appears in System navigation.

The snapshot subprotocol is requested through the `Sec-WebSocket-Protocol` header on the authenticated URLRequest, as supported by [Apple's URLSession WebSocket request API](https://developer.apple.com/documentation/foundation/urlsession/websockettask(with:)-mtks). This source check establishes the API's supported handshake behavior; physical controller handshake verification remains separate.

## Implemented behavior

- Original thermal bed and waveform presentation remain native. Matrix temperature regions and capacitance channel pairs are separate layers, avoiding the previous implication that lateral temperature regions measured head/torso/legs. Temperature follows the owner's Celsius/Fahrenheit preference.
- Core occupancy is polled every three seconds. Controller classification, availability and movement remain separate from local channel activity. Missing, failed, expired or superseded observations never become an Empty/Away claim. The Temperature headers use the same reported state.
- Freezer temperatures decode centidegrees; bedTemp2 retains Celsius. Partial pump/fan/TEC fields remain unknown. Thermal control accepts both scalar and structured firmware dialects. Stored freezer and six-zone bed readings provide fallback while retaining their measurement timestamps; the newest observation wins.
- Bed temperature and humidity history offer 1/6/12/24 hours with server summaries. Flow/RPM history offers 1/6/24/72/168 hours; stored flow integers divide by 100 to match raw firmware diagnostics. No physical flow unit is inferred. Chart runs stop at explicit missing values and long gaps, and retain extrema when reducing plot work.
- Sensor arrival time and measurement time are separate. Cached snapshots preserve source timestamps; future or regressing typed readings cannot replace observations. Connection changes invalidate pending occupancy and piezo analysis. Disconnect clears controller-owned readings and buffers.
- Waveform channels can be hidden individually. Historical inspection uses the read-only get_waveform protocol with request identities and a five-second timeout. Replay never feeds live temperature, occupancy, calibration or vital calculations; Back to live restores the continuously collected live buffer.
- Firmware console includes mode/type filtering, frozen Pause/Resume, raw JSON inspection and sharing, with native light/dark surfaces. Stream Pause/Start is separate from console freeze.

## Validation

Thirty-four focused unit/transport checks passed in `SensorDiagnostics-phone-final-responsive.xcresult`: 23 XCTest cases and 11 Swift Testing cases covering calibration, diagnostics, replay and thermal rendering inputs. This includes occupancy expiry/failure, connection generation, firmware aliases sharing one measurement timeline, unit conversion, chart gaps, derived-history replacement and waveform isolation.

The complete interaction passed on iPad light (`SensorDiagnostics-ipad-final-v2.xcresult`), iPhone dark (`SensorDiagnostics-phone-final-v2.xcresult`) and maximum Dynamic Type (`SensorDiagnostics-accessibility-final-v2.xcresult`), including Pause/Start, capacitance layers, controller presence, freezer data, waveform channel toggles/replay, history ranges, RPM history, console selection/freeze and raw-frame inspection. Thirty-three final captures were exported to `previews/system-sensors/` and visually reviewed. Earlier interrupted runs are not acceptance evidence.

The history review found formatter allocation on each chart render. Timestamps now use value-format parsing and chart points are prepared once per response, retaining gaps and extrema. The UI test improved after that correction, but automation timing is not a physical-device performance benchmark. Multi-day charts label dates, and the console/matrix/control rows adapt at accessibility text sizes. Strict SwiftLint and the native-presentation guard pass. CI and merge remain pending.

## Evidence limits

Tests use in-memory demo clients or `.invalid` transport fixtures. No real Pod mutation is involved. Live controller pairing and physical acceptance remain separate. Version/build stays 0.2.0 (7); final TestFlight release waits for the full parity audit.
