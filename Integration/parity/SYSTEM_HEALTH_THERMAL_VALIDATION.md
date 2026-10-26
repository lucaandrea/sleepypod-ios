# Native health and thermal diagnostics

Status: implementation complete; focused simulator validation and all four CI checks passed; merged into owner main. This is one portion of the parity program, not a TestFlight release or a physical Pod recovery claim.

## Source coverage

Compared against Core's `HealthPanel.tsx`, `healthLogic.ts`, `OccupancyCheck.tsx`, `dataPath.ts`, `LiveStreamTable.tsx`, `streamGroups.ts`, `DiagnosticsConsole.tsx`, `thermalHistoryLogic.ts`, `ThermalHistoryChart.tsx`, and `DeviceSettingsForm.tsx`. Transport contracts come from the `health.ts` and `settings.ts` routers.

Health exposes five data-path stages, node detail and connections, current faults, allowed service restarts, occupancy confirmation and sequential capacitance calibration. The 24-hour history retains recorded gaps, condensed/all checks and grouped incidents. Live-stream inspection groups six frame families, retaining a bounded minute of arrivals separately from raw payloads.

Thermal exposes Live, 1 hour, 12 hours, 24 hours and 7 days, five chart groups and a shared inspection time. Temperature units follow the app preference. Missing samples and long gaps split traces. Target lines and power-on markers remain distinguishable from measurements. Live history is collected only while this screen is open. Current side cards expose reported target, bed/water/surface temperatures, pump speed, flow age, protection blocks and inferred alarm state.

Pump protection has six draft controls. Saving sends only changed fields; a failed save requires a fresh read before another attempt. No sample UI or unit test sends hardware commands.

## Boundaries

- A service restart acknowledgment does not prove recovery. Fresh node output remains authoritative.
- Failed health reads prevent recovery from a retained snapshot. Recovery operations are never automatically retried.
- Core uses a single calibration request file. An empty-bed fix waits for the first side's new completed profile before queuing the second.
- Range changes discard stale thermal history responses. Gaps and unavailable readings are not replaced with zero.
- The thermal router's vibration flag is an inferred command-duration state, not a direct vibration sensor measurement.
- Dashboard, broader hardware/storage workflows and final thermal ownership/intervention reconciliation remain in the overall parity checklist.

## Verification

Xcode 27.1 / iOS 27 simulator compilation passes. Seventeen focused transport/state tests pass (eight Health, nine Thermal), covering restart allowlists and unknown outcomes, sequential calibration, exact routes/patches, stale range responses, history gaps, stream arrival accounting and pump-save readback.

Both interaction flows pass on iPhone in Dark appearance and iPad in Light appearance. Health and Thermal also pass at the largest accessibility text size. The pump steppers now separate their controls from wrapping labels; the final layout also passes the same edit/save flow on standard-size iPhone and iPad. Twenty-seven named screenshots are retained in `previews/health-thermal/`.

An earlier iPad run was interrupted after all 17 unit tests passed because the test scroll gesture did not advance the sheet. Native iPad swipe gestures resolved it. An earlier accessibility Thermal run exposed a wrapping stepper layout; the revised layout passes. These interrupted attempts are not counted as passing flows.

Strict SwiftLint and the native-presentation guard pass. No real Pod restart, calibration, pump-setting mutation or TestFlight release was performed. All demo histories and recovery results are synthetic.

Local result bundles under `build/parity-validation/`: `HealthThermal-ipad.xcresult` (17 passing units before the interrupted UI attempt), `HealthThermal-phone2.xcresult`, `HealthThermal-ipad2.xcresult`, `HealthThermal-accessibility.xcresult` (passing Health flow), and final Thermal flows in `HealthThermal-accessibility-pump.xcresult`, `HealthThermal-phone-pump.xcresult`, `HealthThermal-ipad-pump.xcresult`.

Delivery: PR [#8](https://github.com/lucaandrea/sleepypod-ios/pull/8) merged into owner main at `603311d1b613c14a974823b167ceedec959391bc`; build, contract-test, lint and done passed in GitHub run `40258239487`. No new App Store build was uploaded.
