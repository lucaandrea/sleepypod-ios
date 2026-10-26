# Native sensor calibration

Implemented on 2026-10-25 as part of the ongoing native parity program. This does not complete the System audit or authorize an early TestFlight release.

## Coverage

System → Calibration uses Sleepypod's shared cards and native navigation. Each side exposes Piezo, Capacitance and Temperature profiles with status, quality, sample count, creation time, remaining validity and errors. Individual calibration and Calibrate all require an explicit confirmation that the affected bed side is empty and still. Status refreshes every five seconds in the foreground. Profile expiry and live-signal freshness remain separate.

The recent signal charts show a centered piezo envelope, reference-compensated capacitance channels and their sum, and the three measured temperature zones. Piezo/capacitance retain thirty seconds; temperature retains ten minutes. Baseline bands, presence thresholds, colour legends, scalable readouts and time-inspection sliders expose comparisons without changing the bed. Missing channels retain their positions; missing and stale data are identified. Temperature uses the selected °C/°F unit. Chart axes have compact labels while detailed readouts retain full Dynamic Type scaling.

Core's full calibration request does not immediately replace existing successful profiles. The new workspace captures profile identities before submitting and waits for newly created results for every requested side/sensor. A queued acknowledgment alone cannot show completion. Rejections, partial failures, failed reads, missing timestamps and a two-minute timeout remain visible. No request is automatically retried. Processing already accepted by Core continues if the screen is left.

The old Free Sleep backend has no calibration endpoint. Its broken legacy card and old completion logic have been removed; the new route is available for Core and the explicitly labeled demo.

## Source and transport

Compared against Core's `CalibrationPanel.tsx`, `calibrationSignals.ts`, `normalizeFrame.ts`, and `calibration.ts` router. GET `/api/calibration/status?side=…`, POST `/api/calibration/trigger` and POST `/api/calibration/trigger-all` use the configured owner connection. Demo profiles/signals are synthetic and issue no Pod commands.

The WebSocket decoder now accepts optional ambient/humidity fields in `bedTemp2`, preserves Celsius on current Pods, normalizes centidegrees on legacy `bedTemp`, and accepts legacy capacitance shapes without filling missing channels with valid readings.

## Verification

- Eleven focused tests cover expiry, baseline decoding/conversion, reference compensation, bounded signal windows, missing readings, legacy/current frame contracts, queued-versus-complete identity checks, partial/rejected/unknown results and exact REST requests.
- The final iPhone (dark), maximum Dynamic Type iPhone (dark), and iPad (light) interaction flows pass for side selection, individual calibration, full calibration and all three inspection sliders. Fifteen rendered screenshots are retained under `previews/calibration/`. Native alerts also cover repeated calibration confirmations on iPad.
- Unit tests and demo UI do not establish successful calibration or sensor accuracy on the physical Pod. No live calibration or bed movement has been performed.

- Strict SwiftLint, the native presentation guard and whitespace checks pass. The presentation guard verifies that retired Free Sleep UI is absent.
- Local results: `Calibration-accessibility-final.xcresult` (eleven units and UI), `Calibration-phone-final.xcresult`, `Calibration-ipad-final.xcresult`, and `Calibration-accessibility-alert-final.xcresult` (final alert interaction).

Owner [PR #7](https://github.com/lucaandrea/sleepypod-ios/pull/7) merged into main at `8efb4f3a3bc1e0f4c4c932e04d5ee436d0643bf8`. [CI run 40256500743](https://github.com/lucaandrea/sleepypod-ios/actions/runs/40256500743) passed build, unit/transport regressions, API contracts, strict lint and the aggregate check.
