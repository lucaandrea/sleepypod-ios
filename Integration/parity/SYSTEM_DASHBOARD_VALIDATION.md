# Native System overview and pump incidents

Status: implemented, validated and merged into owner main. This milestone does not complete the wider iOS parity audit or authorize an early release.

## Source and behavior

Audited Core `diagnostics/DashboardPanel.tsx`, `dashboardLogic.ts`, `status/StatusScreen.tsx`, `status/PumpAlertsCard.tsx`, `diagnostics/OccupancyCheck.tsx`, `lib/singleSleeper.ts`, `hardware/pods.ts`, and the `health`, `pumpAlerts`, `settings`, and `system` router contracts.

- Status retains the original native health ring and grouped navigation. Overview adds controller runtime, optional firewall facts, maintenance, pipeline recovery navigation, tonight's plan, and per-side twelve-hour delivery summaries.
- Runtime includes uptime, RSS, sensor source, first-frame time, event-loop timing, heap/external/array-buffer counters, and startup stages. Array buffers are explicitly included in external allocations; the UI does not sum them into RSS.
- Detailed reads run once per minute; thermal delivery and service status refresh every ten seconds while Overview is active. Independent failures retain prior readings, display their error, and invalidate freshness. Cancellation allows detailed reads to resume immediately. Status polling stops when its screen disappears.
- Service receipts advance only on successful status reads. Controller switches clear observations and invalidate late responses; overlapping refreshes are coalesced. Missing Wi-Fi, firewall, latency, model revision, water level and internet state remain unknown. Internet controls display Refresh until the setting is known and require matching controller readback after a write.
- Maintenance covers disabled pump protection only where pump speed is supported or not yet known, low water, last prime, and missing/seven-day prime reminders unless daily priming is enabled. Occupancy concerns link to the existing health/recovery workflow.
- Tonight is 17:00–09:00 in the Pod's timezone and rolls over at 09:00. Calendar arithmetic retains 15- and 17-hour DST nights. Dashed scheduled targets stop at power-off; measured bed samples retain gaps. Side power/alarm markers and a separate Pod-event lane share one inspection position. Inspection never writes to hardware.
- Visible sides follow Core's configured solo mode plus away status. With exactly one active sleeper, only that side appears; otherwise both remain visible. This does not change thermal-zone policy.
- Per-side cards show reported power/target, bed/water/pump readings, telemetry age, powered-since and a twelve-hour chart. Surface measurements are used only when the recent bed-temperature series is absent. Missing values remain dashes and stale snapshots are labeled.
- Pump alerts read up to 500 rows, optionally including acknowledged incidents. The controller excludes dismissed rows. Individual and bulk dismissal preserve the exact reviewed row identities, reject stale/changed reviews, require positive acknowledgments, continue past individual failures, and read back the list. New incidents arriving during a batch are not dismissed. A failed readback disables further dismissal. No automatic mutation retry or claim of measured recovery follows dismissal.
- Water & Priming has an inset action that remains reachable at large text sizes. Starting requires a fresh connection and explicit confirmation. Accepted requests remain distinct from the controller's measured priming state; a refresh is required before another request. Unsupported chemical recommendations and generic standards references were replaced with model-specific [manufacturer maintenance guidance](https://www.eightsleep.com/product/pod-maintenance-insert), inspected 2026-10-25. The manufacturer describes replaceable inserts for Pod 4/5 and different maintenance for older generations; the app does not recommend substitute chemicals.

## Validation

Thirty focused tests pass in `build/parity-validation/SystemOverview-ipad.xcresult`: five dashboard state/time tests, six transport/settings/acknowledgment tests, five status lifecycle tests, four Core hardware-status tests, six pump-alert tests and four existing internet-toggle tests. Tests use deterministic in-memory clients or `.invalid` URLProtocol fixtures; no production endpoint is involved.

The final Overview interaction flow passes in `SystemOverview-phone-reviewed.xcresult`, `SystemOverview-accessibility-final.xcresult` and `SystemOverview-ipad-final.xcresult`: runtime details, maintenance, simulated prime request, tonight inspection, twelve-hour history and Thermal navigation. The final pump-alert flow passes in `PumpAlerts-phone-final.xcresult`, `PumpAlerts-accessibility-fit.xcresult` and `SystemOverview-ipad-final.xcresult`: incident review, per-row dismissal, acknowledged filtering, bulk dismissal and empty state.

Thirty PNG captures under `previews/system-overview/` cover iPhone dark, iPad light and maximum Dynamic Type. The largest-text alert was visually inspected and its explanation/action geometry is asserted by the UI test. Maximum-text history charts use sparse axis labels; the Water action remains inset while its content scrolls. Strict SwiftLint, whitespace checks and the native presentation guard pass.

Publication: [PR #10](https://github.com/lucaandrea/sleepypod-ios/pull/10) merged at `d55bfbbc59c024901e8311ccd255f05c1a2da05d` after all four checks passed in CI run `40262370022` (build, unit/transport regressions, contract tests, lint and aggregate gate).
## Evidence limits

All captured interactions are explicit demo data. The scheduler demo is a dated DST fixture; measured temperature history is separately simulated. No real Pod prime, internet-access change, pump dismissal, recovery, cleanup or vibration command was used for validation. Physical controller integration remains a separate requirement. Version/build stays 0.2.0 (7); no TestFlight upload is part of this milestone.
