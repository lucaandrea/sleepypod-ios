# Native iOS parity with Sleepypod web

Owner request: study the demo and documentation, plan and implement every web capability absent from iOS, retain the existing personal features, then release through Xcode/App Store Connect to the internal group and ciao@luca.ooo. Preserve Sleepypod's native presentation; no retired Free Sleep UI.

Status: **in progress; this is not a completion claim**. ESP32 0.4.1 is installed, connected to the owner's Wi-Fi and out of sample Preview. It awaits the live Core LAN endpoint/key; physical read-only diagnostics and the remaining controller setup are recorded separately in `free-sleep/firmware/waveshare-amoled/docs/HARDWARE_CHECK.md`. Firmware PR #12 is merged into the owner's main. iOS integration PR #1 is merged into owner main at `17b47c66969b824dccdfba087e3c4d4e2fdcaede` after all CI checks passed.

## Evidence and release baseline

- Inspected [the live demo](https://sleepypod.vercel.app/en) on 2026-10-25: Cards, Stage, schedule preview control, Autopilot list/activity and the new automation editor. Demo edits are disposable; no real Pod changes are required for exploration.
- Read [Temperature documentation](https://sleepypod.github.io/core/temperature/), last updated 2026-10-22. It explicitly distinguishes development Stage behavior from released v3.2.1.
- Current local Core revision is recorded with the exact route inventory in `CoreAPIInventory.json`. Existing iOS presentation baseline is upstream `2c1ee99ef0b534d9bcdbcf8fdc313cbf0051075e` plus released integration build 0.2.0 (7).
- Existing iOS Night/Dawn, thermal card, local stage models, Health/Watch comparisons, schedules, run-once, alarms and sensor streaming are present. Existence alone does not prove parity; audit the interactions below.
- The prior byte-identical TempScreen guard must evolve to allow these explicitly requested additions while continuing to reject the retired app shell, views and assets. Keep the existing Cards UI and shared design components.

## Requirement checklist

Each item needs source/API coverage, accessible native UI, loading/error/offline states, and evidence of its primary interaction. A link to a website or an unsupported placeholder does not establish native parity.

### Temperature and appearance

- [ ] Cards/Stage choice, retained per device; existing Dial/Slider/Now–Night–Dawn/Both-sides layouts remain available.
- [ ] Interactive 3D Stage: rotation/zoom/reset, select left/right, controls, live target labels, six measured zones, zone visibility options and camera auto-return preference.
- [ ] Stage schedule timeline with scrub preview and Back to live; preview never writes to the Pod.
- [x] Degrees, whole-Fahrenheit Offset from 80°F, Eight Sleep −10…+10 (82.5°F neutral) independent of °F/°C units; matching increments and accessibility adjustments.
- [ ] Manual hold durations 15/30/60/120 minutes; ownership labels, expiry and Resume.
- [ ] Power, All off and side linking with current web-source semantics and clear failure reporting. The current SideProvider links future changes without an initial hardware copy; this differs from the temperature documentation, so do not introduce surprise actuation.
- [ ] Night/Dawn schedules: matching-day edits, shape-preserving shifts, missing-night setup, no-Dawn single point, side handling and error recovery.
- [ ] Room humidity/light/air, last-night summary, next alarm toggle/editor, tonight's next setpoint and schedule/sleep history.
- [ ] Pump-stall restore/dismiss, priming completion, active alarm stop/snooze/cancel banners.

### Adjustable base

- [ ] 3D articulated preview with mattress/frame, simple view, rotation/zoom and reported/requested positions.
- [ ] Head/feet, supported speeds, presets, optional immediate preset behavior, whole-bed/independent-side capability handling, Stop and reconnect.
- [ ] Base schedule CRUD, side/day/time, conflicts, preset names, enable/disable and confirmation/error states.

### Schedule

- [ ] Compare existing native schedule/curve editor against web: day grouping, copy, presets/templates, point CRUD, power windows, overnight/day offsets and timezone.
- [ ] Alarm CRUD: vibration, temperature, smart wake window, snooze/cancel and next-alarm controls.
- [ ] Run-once create/review/cancel and saved curve templates; preserve existing AI curve tools and routine conflict checks.

### Sleep and biometrics

- [ ] Night/week/month navigation, side selection, summaries and stage lanes; sleep record time edits/deletion.
- [ ] Vitals, HRV, breathing and movement charts with zoom/pan, gaps and raw-record inspection/export.
- [ ] Apple Watch/reference comparison, source distinctions and supported file import/export workflows.
- [ ] Audit web sleep-stage source/model/profile controls against existing local analysis; implement missing remote operations without misrepresenting model qualification.

### Autopilot

- [ ] Global enable, dry-run/halted/active status, current temperature ownership and tonight's rule/schedule timeline.
- [ ] Rule list/create/edit/duplicate/delete/reorder and Off/Dry-run/Active modes.
- [ ] Aggregate/threshold/change/time triggers, signal selection, operators, window sizes and compound conditions.
- [ ] Temperature delta/expression, power and notification actions; clamp, cooldown and revert semantics.
- [ ] Readable rule preview, live evaluation/eligibility, missing-signal handling, backtest night selection/trace and activity filters/pagination.
- [ ] Diagnostics/configuration, signal health/capacitance zones and halt/recovery operations.
- [ ] Preserve and wire personal comfort features supplied by the coordinated Core fork.

### System

- [ ] Dashboard: hardware/services/connection/pipeline summaries and navigation.
- [ ] Calibration: existing sensor calibration parity, status, trigger and result/error presentation.
- [ ] Databases: inventory, table/schema/row browser, filtering/pagination, export and supported deletion with scope confirmation.
- [ ] Hardware: temperatures, pumps/fans, firmware, power, base and device state supported by Core.
- [ ] Health: pipeline stages, freshness/quality, histories and diagnostics.
- [ ] Logs: sources, priority/line controls, streaming/pause/filter/copy/export.
- [ ] Scheduler: scheduled jobs, next executions, schedules and job outcomes.
- [ ] Sensors: piezo/presence, rotatable six-zone thermal bed, measured/stale/missing treatment, filters, environment and firmware console.
- [ ] Storage: usage, counts, retention and supported cleanup/export operations.
- [ ] Thermal: measured/target history, controller ownership, interventions, pump protection and diagnostic trends.

### Settings

- [ ] Appearance: all web controls plus native app preferences.
- [ ] Backup: archive destination/configuration, status/history, test/run and download workflows.
- [ ] Biometric calibration: profiles, processing state, evaluations, shadow/backtest/reference workflows supported in the web UI; inspect each subsection before marking complete.
- [ ] Device: pod-wide hardware/maintenance settings and sensor-source capabilities.
- [ ] Gestures: all tap actions, side bindings, temperature increments and base actions where supported.
- [ ] HomeKit bridge: enable/configuration, pairing info/QR, status and reset; retain native Home controls.
- [ ] MQTT: broker/auth/topic/discovery, TLS options and connection status.
- [ ] Network: current connectivity, internet access and supported network controls.
- [ ] Sides: names/default, bed setup, timezone/away ranges and per-person controls.
- [ ] Sleep stages: rules/preview/source selection and remote model configuration.
- [ ] Updates: version/channel/check/apply/progress, storage and failure recovery.

### Validation and delivery

- [ ] Continue demo exploration through Base, Schedule, Sleep, System's ten tabs and Settings' eleven sections; reconcile findings into this checklist.
- [ ] Add meaningful conversion/transport/model tests, captured Core fixtures and request assertions; never send live actuator mutations for tests.
- [ ] Exercise native routes on iPhone and iPad, light/dark, large text, offline/missing/stale cases; capture rendered artifacts.
- [ ] Re-run existing Health, Shortcuts, schedule and feature integration checks; review privacy/entitlements/licenses.
- [ ] Update version/build and release notes only after the complete parity audit; archive, validate signatures and upload using Xcode.
- [ ] In **Safari**, confirm the new build in App Store Connect, assign Free Sleep Internal and individual ciao@luca.ooo, and verify processing/testing status.
- [ ] Publish truthful final evidence and copyable commit title/description; do not claim physical Pod behavior from fixtures.
- [ ] Owner's 2026-10-25 follow-up: finish and validate this effort's branches/PRs, then merge into the owner's `main`; coordinate outstanding Core work with its owning chat. Do not leave delivery on an unmerged feature branch.

## Current implementation evidence

- Temperature: `TEMPERATURE_VALIDATION.md`; Stage/scales/ownership plus native room and recent-sleep context. Context has 8 transport/state tests and 2 interaction flows passing on iPhone, maximum Dynamic Type and iPad. Remaining history/timeline/notice work is listed there.
- Base implementation: `BASE_VALIDATION.md`; 9 focused unit tests, 2 main UI tests, iPad and maximum-size accessibility UI checks pass. Independent-side/offline UI and final cross-feature checks remain open.
- Alarm implementation: `ALARM_VALIDATION.md`; precise Core rows preserve paused/multiple alarms and overnight fields; native CRUD and next-alarm controls have focused test evidence. Remaining layout/context cases are recorded there.
- Curve library: `CURVE_VALIDATION.md`; owned day assignments, point editing, presets, run-once and legacy compatibility have unit/iPhone/iPad/largest-text evidence. Remaining Schedule audit is still open.
- Sleep and Watch reference data: `SLEEP_VALIDATION.md`; native time edits, range exports, chart controls, source-aware summaries, Watch import/reference workflows and movement/presence semantics are implemented. The advanced stage/model controls and final validation remain open.
- Autopilot: `AUTOPILOT_VALIDATION.md`; native rule language/editor, atomic modes, replay, diagnostics, activity and pressure replay are implemented. iPhone, iPad and maximum-text validation passed. The remaining summary/timeline/configuration workflows are in progress.
- Health rebuild: `HEALTH_REBUILD_VALIDATION.md`; 15 lifecycle checks verify scoped cleanup, incomplete-analysis preservation and stable versions. Device Health authorization/sync remains pending.
- Remote stages and models: `STAGE_VALIDATION.md`; native rule editing/preview/history, capability-gated model library/import/selection, and explicit Pod/iPhone Night sources are implemented. Core model-route alignment, responsive checks and the remaining advanced profile workflows are still in progress.

## Implementation order

1. Temperature display preferences, Core transport and control ownership; interactive Stage and thermal scene.
2. Base, schedules, sleep and sensor interaction parity.
3. Full Autopilot editor, diagnostics and backtests.
4. System and settings workflows, including the advanced biometric panels.
5. Cross-feature/runtime verification, exhaustive requirement audit and TestFlight release.

Work on one cohesive portion at a time without dropping later requirements. No release or goal completion until every applicable checklist item has evidence.
