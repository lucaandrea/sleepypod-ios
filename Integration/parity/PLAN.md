# Native iOS parity with Sleepypod web

Owner request: study the demo and documentation, plan and implement every web capability absent from iOS, retain the existing personal features, then release through Xcode/App Store Connect to the internal group and ciao@luca.ooo. Preserve Sleepypod's native presentation; no retired Free Sleep UI.

Status: **in progress; this is not a completion claim**. ESP32 0.4.1 is installed, connected to the owner's Wi-Fi and out of sample Preview. It awaits the live Core LAN endpoint/key; physical read-only diagnostics and the remaining controller setup are recorded separately in `free-sleep/firmware/waveshare-amoled/docs/HARDWARE_CHECK.md`. Firmware PR #12 is merged into the owner's main. iOS integration PR #1 is merged into owner main at `17b47c66969b824dccdfba087e3c4d4e2fdcaede` after all CI checks passed. Native Autopilot PR #2 is merged at `c9a5975bf83dc853ede790afaa81ec6de178b3e7`, also with all CI checks passing. Night planning PR #3 is merged at `eb6d3942e4ab16ecd1577d27f0bb56f6c293c286` after all four checks passed. Database tools PR #4 is merged at `e531f74cffee6754a6216b0213be5a56481bae43`, with all four checks passing. Scheduler PR #5 is merged at `ff87da8e146189f441a9175dbcf089df39d7a552`, also after all four checks passed. Service logs PR #6 is merged at `ec2acc9b11507de1c983897bdb62f44dbf61cc04` with all four checks passing. Calibration PR #7 is merged at `8efb4f3a3bc1e0f4c4c932e04d5ee436d0643bf8` after the same four checks passed. Health and Thermal PR #8 is merged at `603311d1b613c14a974823b167ceedec959391bc` with all four checks passing. Storage and vibration PR #9 is merged at `a606419c6a097b5edf819c7699260c7af41f0e2e`, also with all four checks passing. System Overview PR #10 is merged at `d55bfbbc59c024901e8311ccd255f05c1a2da05d` after all four checks passed. Sensors PR #11 is merged at `3fbe643caad8b8f6d8f2f1b9a3a737523ac66904`, also after all four checks passed. Connection settings PR #12 is merged at `52c94b2fa1ed8462459bab7eef3abf406baefa3d`, with all four checks passing. Backup PR #13 is merged at `5019f68a1a6fe5b5ececebc561e64a9e8e7a2722`, also after all four checks passed. Device PR #14 is merged at `8c51d6d657e8d216c55f76b228177175844ebf60`, with all four checks passing. Sides and Gestures PR #15 is merged at `78b970f688489351251f0fe9c488297a05dd2108`, also after all four checks passed; its feature branch is removed. Appearance PR #16 is merged at `5e5e5032584a2dafb8eca25ae553f4ad89a7de85` after all four checks passed; its feature branch is removed. Biometric profiles PR #17 is merged at `2b3196a72a3813f856d7b744890b7cddc7f55263` after all four checks passed; its feature branch is removed. Biometric references PR #18 is merged at `656a6bece44b38c198fc6ed7c18dfb820189ed43` after all four checks passed, including the Xcode 26 compatibility correction; its feature branch is removed.

Evaluation jobs PR #22 is merged at `a92f69883fcc9772c13513a53aefa3ad25d2f313` after all four checks passed; its feature branch is removed. Native reports and trace inspection PR #23 passed all four GitHub checks and merged at `9c8510679d1d2acadb0577de3de6b290a16520e5`; its feature branch is removed. Evaluated profile application PR #24 passed all four GitHub checks and merged at `2b8e3077a29ddb1cd86424a615d341f0b09c2213`. Its targeted logic/transport and phone/iPad/maximum-text checks pass. Prospective observations PR #25 passed all four GitHub checks and merged at `4a7ecb87bc4951e9fefe133a4d7b857b0430958c`; its feature branch is removed.

## Evidence and release baseline

- Inspected [the live demo](https://sleepypod.vercel.app/en) on 2026-10-25: Cards, Stage, schedule preview control, Autopilot list/activity and the new automation editor. Demo edits are disposable; no real Pod changes are required for exploration.
- Read [Temperature documentation](https://sleepypod.github.io/core/temperature/), last updated 2026-10-22. It explicitly distinguishes development Stage behavior from released v3.2.1.
- Current local Core revision is recorded with the exact route inventory in `CoreAPIInventory.json`. Existing iOS presentation baseline is upstream `2c1ee99ef0b534d9bcdbcf8fdc313cbf0051075e` plus released integration build 0.2.0 (7).
- Existing iOS Night/Dawn, thermal card, local stage models, Health/Watch comparisons, schedules, run-once, alarms and sensor streaming are present. Existence alone does not prove parity; audit the interactions below.
- The prior byte-identical TempScreen guard must evolve to allow these explicitly requested additions while continuing to reject the retired app shell, views and assets. Keep the existing Cards UI and shared design components.

## Requirement checklist

Each item needs source/API coverage, accessible native UI, loading/error/offline states, and evidence of its primary interaction. A link to a website or an unsupported placeholder does not establish native parity.

### Temperature and appearance

- [x] Cards/Stage choice, retained per device; existing Dial/Slider/Now–Night–Dawn/Both-sides layouts remain available.
- [x] Interactive 3D Stage: rotation/zoom/reset, select left/right, controls, live target labels, six measured zones, zone visibility options and camera auto-return preference.
- [x] Stage schedule timeline with scrub preview and Back to live; preview never writes to the Pod. Saved calendar targets, current Run Once and recorded power/presence are distinct from Autopilot observations; see `TEMPERATURE_HISTORY_PHASES_AUDIT.md`.
- [x] Degrees, whole-Fahrenheit Offset from 80°F, Eight Sleep −10…+10 (82.5°F neutral) independent of °F/°C units; matching increments and accessibility adjustments.
- [x] Manual hold durations 15/30/60/120 minutes; ownership labels, expiry and Resume.
- [x] Power, All off and side linking follow current web-source semantics and clear failure reporting. Linking affects future changes without an initial hardware copy. Final interaction evidence is in `NATIVE_CONTROLS_RECONCILIATION.md`.
- [x] Night/Dawn schedules: matching-day edits, shape-preserving shifts, missing-night setup, no-Dawn single point, side handling and error recovery.
- [x] Room humidity/light/air, last-night summary, next alarm toggle/editor, tonight's next setpoint and schedule/sleep history. Active-sleeper context and all layouts are reconciled in `ALARM_CURVE_RECOVERY_AUDIT.md`.
- [x] Pump-stall restore/dismiss, priming completion, active alarm stop/snooze/cancel banners.

### Adjustable base

- [x] 3D articulated preview with mattress/frame, simple view, rotation/zoom and reported/requested positions.
- [x] Head/feet, supported speeds, presets, optional immediate preset behavior, whole-bed/independent-side capability handling, Stop and reconnect.
- [x] Base schedule CRUD, side/day/time, conflicts, preset names, enable/disable and confirmation/error states.

### Schedule

- [x] Native schedule/curve editor reconciled against web: day grouping, copy, presets/templates, point CRUD, power windows, overnight/day offsets and timezone. See the temperature/phases and controls audits.
- [x] Alarm CRUD: vibration, temperature, smart wake window, snooze/cancel and next-alarm controls. One-occurrence personal overrides remain a separate Core integration.
- [x] Run-once create/review/cancel, saved curve templates and AI curve tools; reviewed native bedtime routines preserve conflict checks. See `ALARM_CURVE_RECOVERY_AUDIT.md` and `BEDTIME_ROUTINES_AUDIT.md`.

### Sleep and biometrics

- [ ] Night/week/month navigation, side selection, summaries and stage lanes; sleep record time edits/deletion.
- [ ] Vitals, HRV, breathing and movement charts with zoom/pan, gaps and raw-record inspection/export.
- [ ] Apple Watch/reference comparison, source distinctions and supported file import/export workflows.
- [ ] Audit web sleep-stage source/model/profile controls against existing local analysis; implement missing remote operations without misrepresenting model qualification.

### Autopilot

- [x] Global enable, dry-run/halted/active status, current temperature ownership and tonight's rule/schedule timeline. See `AUTOPILOT_DIAGNOSTICS_AUDIT.md` and `AUTOPILOT_PLANNING_VALIDATION.md`; physical qualification remains separate.
- [x] Rule list/create/edit/duplicate/delete/reorder and Off/Dry-run/Active modes.
- [x] Aggregate/threshold/change/time triggers, signal selection, operators, window sizes and compound conditions.
- [x] Temperature delta/expression, power and notification actions; clamp, cooldown and revert semantics.
- [x] Readable rule preview, live evaluation/eligibility, missing-signal handling, backtest night selection/trace and activity filters/pagination. See `AUTOPILOT_DIAGNOSTICS_AUDIT.md` and `AUTOPILOT_PLANNING_VALIDATION.md`; physical qualification remains separate.
- [x] Diagnostics/configuration, signal health/capacitance zones and halt/recovery operations. See `AUTOPILOT_DIAGNOSTICS_AUDIT.md` and `AUTOPILOT_PLANNING_VALIDATION.md`; physical qualification remains separate.
- [x] Persistent native alert inbox, foreground delivery and explicit acknowledgment using the coordinated Core notification contract (PR #28, main 7fa390a75ce3358e39d59ac016b66c0d38144ac3). Background push is unavailable; keep historical/expired and stale reads distinct.
- [x] Preserve and wire personal comfort features supplied by the coordinated Core fork, including bed-entry Preview and reviewed nightly reports. PR #30 is merged; atomic mode-only Shortcuts and the full journal remain under personal API reconciliation.
- [x] Native room-sensor mapping, source-time freshness, history and Home presentation from Core PR #29 (`cbb0e5bd45c723888e44e8506ef91fdf9b380630`, `docs/ROOM_CONTEXT.md`); setup never implicitly enables an automation.

### System

- [x] Dashboard: hardware/services/connection/pipeline summaries and navigation, runtime/maintenance, night inspection, twelve-hour history and reviewed pump incidents.
- [x] Calibration: existing sensor calibration parity, status, trigger and result/error presentation.
- [x] Databases: inventory, table/schema/row browser, filtering/pagination, CSV export and online backup; the inspected row browser is read-only.
- [x] Hardware: the web Hardware tab is the single-side vibration test (`SystemScreen.tsx` → `HapticsTestCard`). Pump/water readings are covered by Thermal; fan/firmware telemetry remains in the Sensors audit, and power/base controls remain in their dedicated sections.
- [x] Health: pipeline stages, freshness/quality, histories and diagnostics.
- [x] Logs: sources, priority/line controls, streaming/pause/filter/copy/export.
- [x] Scheduler: scheduled jobs, next executions, recurrence and sync/drift diagnostics. Core exposes plans here; execution outcomes belong to service logs.
- [x] Sensors: piezo/presence, rotatable six-zone thermal bed, measured/stale/missing treatment, filters, environment and firmware console.
- [x] Storage: usage, counts, retention and supported cleanup/export operations. The Storage tab exposes eligible-leftover cleanup; database backups/CSV exports are covered by Databases.
- [x] Thermal: measured/target history, five diagnostic trend panels, pump protection, guard/vibration state and thermal side summaries. The current web Thermal tab does not contain ownership/intervention controls; their remaining coverage stays under Temperature and Autopilot.

### Settings

- [x] Appearance: all web controls plus native app preferences. Stage camera/selection behavior remains in the Temperature audit.
- [x] Backup: nightly SSH archive destination/configuration, public-key generation/copy/share, saved-destination connection test and existing database downloads. The audited web section has no run-now or archive delivery-history/status endpoint; nightly delivery belongs to its systemd timer.
- [x] Biometric calibration: profiles, processing state, evaluations, shadow/backtest/reference workflows. The linked PR #17–25 audits cover each web subsection, native lifecycle and rendered interaction; physical processor adoption remains unverified.
- [x] Device: pod-wide hardware/maintenance settings, independent clocks, LED schedules, sensor-source capabilities and reviewed restart/reconnect.
- [x] Gestures: per-side double/triple/quad temperature and alarm/power bindings, normal/ringing behavior, edit/delete and uncertain-result recovery. The audited Core does not support base-angle gesture actions.
- [x] HomeKit bridge: enable/configuration, pairing info/QR, status and reset; retain native Home controls.
- [x] MQTT: broker/auth/topic/discovery, TLS options and connection status.
- [x] Network: current connectivity, internet access and supported network controls.
- [x] Sides: names/default, two/solo bed setup, away return dates, always-on and presence-based auto-on/off with Pod-timezone windows. Global timezone is editable under Device.
- [x] Sleep stages: rules/preview/source selection and remote model configuration.
- [x] Updates: installed version/channel/review/apply, reconnect observation, storage and explicit failure/network recovery. The server exposes no remote latest-version comparison or percentage progress.

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

- Temperature: `TEMPERATURE_VALIDATION.md`; Stage/scales/ownership plus native room and recent-sleep context. Context has 8 transport/state tests and 2 interaction flows passing on iPhone, maximum Dynamic Type and iPad. History, Run Once and Night/Dawn source/REST reconciliation are recorded in `TEMPERATURE_HISTORY_PHASES_AUDIT.md`; notice/camera and final controls checks remain.
- Base implementation: `BASE_VALIDATION.md`; 9 focused unit tests, 2 main UI tests, iPad and maximum-size accessibility UI checks pass. Independent-side/offline UI and final cross-feature checks remain open.
- Alarm implementation: `ALARM_VALIDATION.md`; precise Core rows preserve paused/multiple alarms and overnight fields; native CRUD and next-alarm controls have focused test evidence. Remaining layout/context cases are recorded there.
- Curve library: `CURVE_VALIDATION.md`; owned day assignments, point editing, presets, run-once and legacy compatibility have unit/iPhone/iPad/largest-text evidence. Remaining Schedule audit is still open.
- Sleep and Watch reference data: `SLEEP_VALIDATION.md`; native time edits, range exports, chart controls, source-aware summaries, Watch import/reference workflows and movement/presence semantics are implemented. Advanced stage/model controls are covered by PR #26; final combined validation remains open.
- Autopilot: `AUTOPILOT_VALIDATION.md`; native rule language/editor, atomic modes, replay, diagnostics, activity and pressure replay are implemented. iPhone, iPad and maximum-text validation passed. Multi-night summaries, the shared night timeline, combined replay charts and live/recorded contact zones are implemented and validated in `AUTOPILOT_PLANNING_VALIDATION.md`. Final diagnostics/configuration reconciliation is recorded in `AUTOPILOT_DIAGNOSTICS_AUDIT.md`, including owner-scoped uncertain-save recovery and maximum-text evidence.
- Sides and gestures: `SETTINGS_SIDES_GESTURES_AUDIT.md`; targeted sleeper/bed drafts and tap mapping CRUD have 21 focused checks and both interaction flows on iPhone, iPad and maximum text. Presence freshness, mutual exclusion, saved receipts and uncertain writes are covered; physical changes remain unverified.
- Device: `SETTINGS_DEVICE_AUDIT.md`; targeted preferences, 12/24-hour display, sensor source and restart/reconnect have fifteen focused checks plus iPhone/iPad/maximum-text interaction evidence. The restart route requires the coordinated Core implementation; physical operation remains unverified.
- Backup: `SETTINGS_BACKUP_AUDIT.md`; destination/datasets, public key and saved-target testing are implemented with draft/conflict/unknown-result handling. Nine focused checks and iPhone/iPad/maximum-text flows pass; physical archive delivery remains unverified.
- Appearance: `SETTINGS_APPEARANCE_AUDIT.md`; all display preferences, immediate theme changes, isolated settings patches, stale-response protection and save reconciliation are implemented. Thirteen focused checks, full preference/relaunch flows and the separate units-row flow pass on iPhone/iPad/maximum text; twelve rendered captures are retained.
- Biometric profiles: `BIOMETRIC_PROFILES_AUDIT.md`; Overview, candidate parameters/stage rules, comparison, manual activation/defaults/recovery and history are implemented. Seventeen focused checks and seventeen stage/model regressions pass, along with iPhone/iPad/maximum-text flows and twenty-seven captures. Backtests and Observations are covered by their later audits; physical processor adoption is unverified.
- Biometric references: `BIOMETRIC_REFERENCES_AUDIT.md`; bounded CSV/JSON import, Core preview, explicit partial-row acceptance, immutable corrections, normalized record inspection and source deletion are implemented. Eighteen focused checks and iPhone/iPad/maximum-text flows pass; twenty-four reference captures plus two profile contrast captures are retained. Backtest reference overlays remain in the report audit; no personal health records or live Pod changes were used.
- Biometric datasets: `BIOMETRIC_BACKTESTS_AUDIT.md`; recorded-session capability inspection, reference selection, reviewed frozen inputs, retained libraries, nominal coverage/partitions and confirmed release are implemented. Twelve focused checks and iPhone/iPad/maximum-text flows pass with twenty-four captures. Dataset PR #19 merged at `74404b0a738c4f30240113515352ad4a7743c269` after all four GitHub checks passed. Experiments, jobs/reports and evaluated application are covered by their later audits; no live records were used.
- Biometric waveforms: `BIOMETRIC_WAVEFORMS_AUDIT.md`; inspected source pages, recorded inventories, foreground resource checks, explicit archive scans, whole-night selection and exact-request retention are implemented. Thirteen focused checks plus twelve dataset regressions and phone/iPad/maximum-text flows pass. All twenty-one final captures are reviewed; PR #20 passed all four GitHub checks and merged at `08e7306cd8f5d0e9efe68adf8c31d5738da9d956`. Experiments, jobs/reports and evaluated application are covered by their later audits.
- Biometric experiments: `BIOMETRIC_EXPERIMENTS_AUDIT.md`; protocol editor, immutable library and protected exact-request recovery are implemented. Twelve focused checks, nineteen input regressions and phone/iPad/maximum-text flows pass; twenty-one captures are reviewed. PR #21 passed all four GitHub checks and merged at `ab787d85b406a6ea9a044eceed6416b56515740c`. Queueing, jobs/reports and evaluated application are covered by their later audits.
- Prospective observations: `BIOMETRIC_OBSERVATIONS_AUDIT.md`; reviewed templates/candidates/windows, protected scheduling recovery, run status/stop, health/coverage/resources and bounded reference comparison are implemented. Ten focused checks and phone/iPad/maximum-text flows pass; all 36 captures are reviewed. PR #25 passed all four GitHub checks and merged at `4a7ecb87bc4951e9fefe133a4d7b857b0430958c`. Synthetic example reports never populate new demo runs; actual processing remains unverified.
- Evaluated profile application: `BIOMETRIC_VALIDATED_ACTIVATION_AUDIT.md`; exact evaluation review, current eligibility/diff, protected retry and separate processor acknowledgement are implemented. Eight new checks, report/profile regressions and phone/iPad/maximum-text flows pass; PR #24 passed all four GitHub checks and merged at `2b8e3077a29ddb1cd86424a615d341f0b09c2213`. Demo examples cannot qualify application.
- Biometric reports: `BIOMETRIC_REPORTS_AUDIT.md`; retained numerical/stage comparisons, exact traces, reference overlays, frozen thresholds, processing observations and protected release recovery are implemented. Fourteen logic/REST checks, queue regressions, iPhone/iPad/maximum-text flows and 54 reviewed captures pass. PR #23 passed all four GitHub checks and merged at `9c8510679d1d2acadb0577de3de6b290a16520e5`; evaluated application and prospective observations are covered by their later audits.
- Biometric evaluation queue: `BIOMETRIC_JOBS_AUDIT.md`; exact candidate/partition review, protected queue retries, job pages/progress and confirmed cancellation are implemented. Fourteen focused checks and twenty-three profile/experiment regressions pass, along with phone/iPad/maximum-text flows; all twenty-one captures are reviewed. Reports, traces and evaluated application are covered by their later audits.
- Room context: `ROOM_CONTEXT_AUDIT.md`; owner-scoped mappings, current measurements, generated publishers and paged historical export are implemented. Eleven focused checks and both phone/iPad/maximum-text flows pass; 25 captures are reviewed, including the corrected large-text selector. Real MQTT measurements remain unverified; PR #27 merged at `d655af38653f22097f89e9c863e9a52582d149d3` with all four GitHub checks passing.
- Alert inbox: `ALERT_INBOX_AUDIT.md`; shared owner-scoped history, foreground delivery, explicit acknowledgment and lost-response readback/retry are implemented. Ten focused checks, phone/iPad/maximum-text flows and twelve reviewed captures pass. Ordinary Demo stays empty; a separate synthetic example has no real effects. PR #27 merged with all four GitHub checks passing.
- Controller Updates: `CONTROLLER_UPDATES_AUDIT.md`; installed build/channel review, protected non-replaying dispatch, read-only reconnect observation and explicit network recovery are implemented. Thirteen focused checks and phone/iPad/maximum-text flows pass, with twelve reviewed captures. Real updater/firewall execution remains unverified; PR #27 merged with all four GitHub checks passing.
- Connection settings: `SETTINGS_CONNECTIONS_VALIDATION.md`; native HomeKit bridge, MQTT and Network match the audited web sections. Twenty-eight focused checks plus all three flows on iPhone/iPad/maximum text pass. Live bridge pairing, broker operation and firewall changes remain unverified.
- System sensors: `SYSTEM_SENSORS_VALIDATION.md`; reported occupancy, freezer telemetry, measured/stale thermal layers, waveform replay, range histories and raw-frame console are implemented. Thirty-four focused checks and iPhone/iPad/maximum-text interaction flows pass. Physical controller pairing remains separate.
- System overview: `SYSTEM_DASHBOARD_VALIDATION.md`; runtime, maintenance, Pod-timezone night inspection, twelve-hour delivery history, pump incidents and water/priming review are implemented. Thirty focused tests plus iPhone dark, iPad light and maximum-text interactions pass; captures retain the native cards and grouped navigation. PR #10 is merged after all four GitHub checks passed.
- System storage and vibration: `SYSTEM_STORAGE_VALIDATION.md` and `SYSTEM_HARDWARE_VALIDATION.md`; reviewed cleanup with backup opt-in, single-side vibration presets, and unknown hardware status handling are implemented. Sixteen focused tests and iPhone/iPad/maximum-text interactions pass; Hardware tab parity is complete against `SystemScreen.tsx`; Overview and the broader Sensors audit are tracked separately.
- System health and thermal: `SYSTEM_HEALTH_THERMAL_VALIDATION.md`; data-path stages, recovery/readback, history/stream inspection, five thermal charts and explicit pump-protection drafts are implemented. Seventeen focused tests and iPhone/iPad/largest-text interactions pass. Thermal-tab reconciliation is complete against `DiagnosticsConsole.tsx`; ownership/intervention work remains under Temperature and Autopilot.
- System calibration: `CALIBRATION_VALIDATION.md`; per-side profiles, baseline charts, expiry and confirmed new calibration results are implemented. Eleven focused tests and iPhone/largest-text/iPad interaction flows pass. Physical Pod calibration remains unverified.
- System logs: `SYSTEM_LOGS_VALIDATION.md`; dynamic sources, priority and line limits, Follow/Pause, text filtering and raw-line copy/file export are implemented. Seven focused tests and iPhone/largest-text/iPad interaction flows pass. Live Pod export remains unverified.
- System scheduler: `SYSTEM_SCHEDULER_VALIDATION.md`; seven Pod-timezone nights, planned target/event inspection, recurrence, next executions and searchable/type-filtered jobs are implemented. Eight focused tests and iPhone/largest-text/iPad interactions pass. Physical execution remains unverified.
- System databases: `SYSTEM_DATABASE_VALIDATION.md`; inventory, integrity/migrations, retention/growth, occupied write gaps, exact-filtered rows, page CSV and streamed backups are implemented. Focused units and iPhone/largest-text/iPad interactions pass; live archive restoration and physical file protection remain unverified.
- Health rebuild: `HEALTH_REBUILD_VALIDATION.md`; 15 lifecycle checks verify scoped cleanup, incomplete-analysis preservation and stable versions. Device Health authorization/sync remains pending.
- Remote stages and models: `STAGE_VALIDATION.md`; native rule editing/preview/history, capability-gated model library/import/selection, and explicit Pod/iPhone Night sources are implemented. Core model-route alignment, 4 MiB imports, chosen-model previews and actual classifier identity/fallback are covered by `STAGE_MODEL_ALIGNMENT.md`; 27 focused checks, phone/iPad/maximum-text flows and 21 reviewed captures pass. PR #26 passed all four GitHub checks and merged at `d149cf5d94cf0b9b11a3b9caf725d625b3b66b34`; its feature branch is removed.

## Implementation order

1. Temperature display preferences, Core transport and control ownership; interactive Stage and thermal scene.
2. Base, schedules, sleep and sensor interaction parity.
3. Full Autopilot editor, diagnostics and backtests.
4. System and settings workflows, including the advanced biometric panels.
5. Cross-feature/runtime verification, exhaustive requirement audit and TestFlight release.

Work on one cohesive portion at a time without dropping later requirements. No release or goal completion until every applicable checklist item has evidence.


Controller updates, alert inbox and room mapping are integrated by PR #27 after all four CI checks passed (`d655af38653f22097f89e9c863e9a52582d149d3`); the branch is removed. Temperature history and Night/Dawn reconciliation continue in `TEMPERATURE_HISTORY_PHASES_AUDIT.md`.

Temperature history and Night/Dawn PR #28 passed all four GitHub checks and merged into owner main at `473656e3c26c35bd4a9804bccd864bd388268557`; its feature branch was removed. Final controls, curve dragging and scoped save reconciliation are tracked in `NATIVE_CONTROLS_RECONCILIATION.md`.

The remaining control interactions passed all four CI checks and merged in PR #29 at `7ca0cc74a59d7f8828d00a049b148fb977afcc69` (`NATIVE_CONTROLS_RECONCILIATION.md`); its feature branch is removed. The first device-CI compiler timeout was corrected by splitting the curve handle view; the local generic-iOS build and the graph drag/save/cancel regression pass. Personal comfort now has direct Core Preview settings, sensor/entry guards, check-ins and exact overnight report review (`PERSONAL_COMFORT_AUDIT.md`), with twelve focused checks and both flows on phone/iPad/maximum text. Its mode-only Shortcut mapping remains in the final integration work.

Complete native bedtime routines now use versioned Core routes and reviewed atomic whole-night saves (`BEDTIME_ROUTINES_AUDIT.md`). Alarm/temperature context for solo and away states, stale-read handling, curve AI/legacy UI, personal API mapping and final release checks remain in progress.

Personal comfort and bedtime routines PR #30 passed all four GitHub checks (run `40313931325`) and merged into owner main at `ff11184a52b7303555210be67bccc4d96e133258` on October 26. The reviewed native routes and Core contracts are documented in `PERSONAL_COMFORT_AUDIT.md` and `BEDTIME_ROUTINES_AUDIT.md`. Alarm-context/curve recovery is tracked in `ALARM_CURVE_RECOVERY_AUDIT.md`; imported history, Autopilot diagnostics, personal API/Shortcuts and final release validation remain open.

Alarm context and curve recovery PR #31 passed all four GitHub checks (run `40317013222`) and merged into owner main at `cab5202be577ec9ffd898c3af02d05ed4eb2087b` on October 26. Its branch is removed. Native imported history is implemented against Core `5297048`, with source-labelled read-only browsing, preserved interval evidence, source-aware paging and accessible navigation (`IMPORTED_HISTORY_AUDIT.md`). CI/merge and the remaining personal integrations, Autopilot reconciliation and release checks are still in progress.

Imported history PR #32 passed all four GitHub checks (run `40319708069`) and merged into owner main at `7d1efb59acca9ace94033c3c367b23b1a7be971d` on October 26. Its feature branch is removed. Autopilot diagnostics and uncertain-save recovery are tracked in `AUTOPILOT_DIAGNOSTICS_AUDIT.md`; the journal, personal API/Shortcuts, Health consolidation and final release validation remain in progress.
