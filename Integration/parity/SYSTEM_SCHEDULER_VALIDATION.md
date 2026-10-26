# Native System scheduler

Implemented and locally validated on 2026-10-25; owner CI/merge remain pending. This is one System capability, not completion of the full parity program or a new TestFlight release.

## Coverage

The existing Status screen links to a native scheduler summary with enabled/sync/drift state, complete group counts, seven selectable nights, per-side scheduled targets and power/alarm markers, read-only timeline inspection, every nightly occurrence, the next five occurrences, and a searchable/type-filtered loaded-job list. Jobs retain their identifiers, original recurrence expression, one-time status and reported next execution. Unknown job types remain visible under Other. Missing next times and missing sync state remain unknown.

Night buckets run from noon to the next noon in the controller's returned timezone, with actual calendar arithmetic across daylight-saving changes. The chart starts at 17:00 and ends at 09:00, expanding for side jobs outside that window. Midday Pod maintenance remains in the occurrence list without compressing the overnight chart. A gap before a setpoint, after power-off or after run-once ends does not invent a target or claim live power state. Target segments and their detail readouts are plans, not measured temperatures or execution receipts.

Timeline refresh runs once per minute while the view is active, with explicit refresh and stale/error states. Sync health can fail independently of timeline retrieval. The all-jobs detail identifies its snapshot time and returns to Scheduler for refresh. Demo inventory is explicitly synthetic and issues no controller requests.

## Source contracts

Inspected owner Core `src/server/routers/health.ts`, `src/components/diagnostics/SchedulerPanel.tsx` and `schedulerLogic.ts` on 2026-10-25. Native reads GET `/api/health/scheduler-timeline?days=8` and GET `/api/health/system` through the configured owner connection. No job mutation or hardware command is added.

## Validation

Results are retained under ignored `build/parity-validation/` using Xcode 27.1 and iOS/iPadOS 27:

- `Scheduler-phone3.xcresult`: all eight model/transport cases, the full scheduler interaction and the existing database filter/paging interaction passed after Status began expanding the gear sheet. Quick settings retain their compact entry.
- `Scheduler-accessibility-final.xcresult`: eight cases and the full interaction passed at the largest accessibility text size after the chart labels were corrected.
- `Scheduler-ipad-final.xcresult` and `Scheduler-phone-final.xcresult`: night selection, target inspection and job filtering passed with the final labels in Light iPad and Dark iPhone layouts.
- Eight model/transport cases cover spring/fall daylight-saving boundaries, morning/night and exclusive-noon grouping, absent targets and end events, maintenance/axis semantics, occurrence identity, unknown kinds, recurrence parsing, exact GET routes and failed-refresh state.
- Six retained PNGs in `previews/system-scheduler/` show final iPhone, largest-text iPhone and Light iPad rendering. Visual inspection caught overlapping chart tick text even though the first accessibility interaction passed; start/end labels now use a separate adaptive layout. Initial normal test attempts were interrupted because broad scrolling skipped controls/collapsed the sheet. Those attempts are not passing evidence.
- Strict SwiftLint, compiled-source presentation guard and `git diff --check` passed. No retired Free Sleep presentation is compiled.
- Tests use synthetic records and simulated transport. No live controller requests or physical job execution are claimed.

Owner PR/CI merge: pending publication. Remaining System/settings parity and final TestFlight delivery continue separately.
