# Web interaction audit — 2026-10-25

These observations use the public demo, not a live Pod. Local API/source inspection is recorded separately in `CoreAPIInventory.json`.

## Temperature and Autopilot

- Explored Cards, Stage, live labels, measured regions and the schedule preview control. The web's slider did not change with the first keyboard attempt; no successful web scrub is claimed yet.
- Opened Autopilot's list and unsaved new-rule editor: Aggregate/Threshold/On change/Time of day, AND conditions, delta/expression actions, clamps, cooldown/revert, five-night backtests and activity. Cancelled the editor without saving.
- Documentation describes initial-copy linking, but current `src/providers/SideProvider.tsx` only links subsequent changes. Native behavior follows current source and does not actuate hardware merely from linking.

## Base

- Opened Base and unchecked Show mattress. Selected Read (40°/0°), then 75% speed. Verified requested position changes while the reported position remains 30°/15° and a separate Move button is required. No movement command issued.
- The demo labels the integration experimental and locks independent-side movement; 25% speed is disabled. Native controls must follow reported capabilities instead of assuming independent actuators.
- Base schedule supports Daily/Weekdays/Weekends/individual day, time, side, preset, list enablement and deletion. Page explains away-mode pause and missed-adjustment skipping.

## Schedule

- Opened a saved Cool weeknights curve, then cancelled without saving. Curve names and notes, independent enablement, day ownership, bedtime/wake, maintain/turn-off ending, coolest/warmest bounds, presets, AI curve, draggable points, individual point editor/deletion and Add set point are visible.
- Opened Edit Weekdays alarm. In addition to side, days, time, pattern/intensity/duration and wake temperature, it has a wake window (Off/10/15/20/30 minutes), snooze length and snooze taper (Off/30/40/50/60%). These fields must survive native reads/edits; the existing simplified `AlarmSchedule` does not represent all of them.

## Sleep

- Inspected Nights, zoomed the vitals chart to 2×, panned it and opened the sleep record time editor without saving. Night/week/month, Watch overlays, four vitals lanes, raw export and record deletion are present.
- Inspected Biometrics: range/date selection, Watch upload, session summaries, raw log/files, and distinctions between processing runs and HRV definitions. Native comparisons must retain provenance and distinguish Watch SDNN from the Pod's window variability metric.

## Still to explore

Sleep reference import/export workflows, all System panels, Settings' eleven sections and Autopilot diagnostics. No full-parity claim or release is justified yet.

## System walkthrough

All ten sections were opened in the public demo. This is an interaction audit, not evidence that equivalent native routes are complete.

- Dashboard: service health tally, build/Wi-Fi/internet/firewall/disk/uptime, pump alerts, tonight's multi-lane schedule and live target/bed/water/pump summaries. Demo dashboard and Health can disagree; preserve each source's freshness rather than merging them into a fabricated healthy state.
- Calibration: selected the right side; piezo, capacitance and temperature show separate status, window/band charts, sample count, quality and validity. Per-sensor recalibration and Calibrate all are exposed; none triggered.
- Databases: inventory, WAL/free pages/migrations, integrity history, growth/retention projection, table selection, read-only rows, filtering, pagination, Copy CSV and online-backup download. Applied a side=left filter and paged to older rows. No row deletion was offered in this panel; source review must determine whether any supported deletion belongs elsewhere.
- Hardware: the demo offers per-side vibration tests with Quick/Standard/Long/Custom patterns, Play and duration. No vibration started; inspect the custom editor before completion.
- Health: selected Piezo processor in the sensor→service→output path. Details distinguish idle from failure, show service identity and log navigation, a 24-hour sampled history and incidents. The demo had a DAC-monitor fault despite the general dashboard's healthy badge.
- Logs: service sources, level tabs, text filter, Follow, refresh, copy/download and firmware-console access. Paused Follow, selected Warn and filtered for `dac`; matching warnings remained. No firmware command sent.
- Scheduler: sync state, job counts by type, tonight/day selector, power/temperature/alarm/maintenance lanes, next-up and all-jobs expansion.
- Sensors: six-region thermal bed with fixed scale and gray stale/missing states, presence zones, freezer/pump/flow/fan/TEC state, bed/environment history, 500 Hz piezo with side filtering and replay position. Switched flow→RPM, selected 24h and hid the right piezo trace.
- Storage: usage categories/raw-history retention, eMMC wear and hourly write-rate history, recording controls (diagnostic logging/temporary debug, health timeline, raw archive), reclaimable release/staging files and optional old backups. Selected an earlier write-rate sample. No recording setting or cleanup changed.
- Thermal: live/1h/12h/24h/7d history with bed/target, water, surface, pump RPM, hub temperatures and power lanes; live per-side summaries and flow age. Switched to Live and verified the one-minute view.

## Appearance detail

The current demo says camera auto-return happens after **eight seconds**, with nothing selected. Reconcile this detail with the native Stage behavior before closing that checklist item.

## Settings walkthrough, continued

- Backup: nightly SSH push toggle, host/port/user/path, raw/biometrics inclusion, public-key generation and a non-destructive connection test. No settings saved, key generated or test run.
- Device: Pod timezone, temperature/time units, curve end action, 1–48h auto-off cap, pump stall/recovery thresholds, reconnect/restart, daily reboot/prime, LED and night brightness window. No mutations.
- Gestures: per-side double/triple/quad taps, regular action (temperature/power/nothing) and ringing-alarm action (snooze/stop). Opened and cancelled the double-tap editor.
- HomeKit: running/enabled, one paired home and reset pairing. Reset not invoked.
- MQTT: connection/publish status, bridge/discovery toggles, broker URL/TLS, username/password, topic prefix, test and save. Inspected without changes.

## Alarm source reconciliation

Reopened the live alarm editor and verified per-alarm snooze length and taper. These are on upstream **dev `47034d44b9dd113890ca05e3ba6af38a29978e1d`**, not upstream main or the earlier local fork. Contracts: `snoozeDuration` 60–1800 seconds, `snoozeTaper` 0/30/40/50/60 percent; optional native decoding preserves older controllers. The coordinating Core chat was asked to integrate these changes. The manual Temp notice still explicitly snoozes for 5m in upstream dev; scheduled/gesture snooze behavior must not be conflated with that button.

Sources inspected at that immutable revision: `src/components/Schedule/AlarmEditor.tsx`, `src/server/routers/schedules.ts`, `src/server/validation-schemas.ts`, `src/hardware/snoozeLength.ts`, `src/server/routers/device.ts`, and `src/components/TempScreen/useTempNotices.tsx`.


## Additional settings walkthrough (2026-10-25)

- Network exposes internet/local-only mode; demo mutation disabled.
- Sides includes two sleepers / solo left / solo right, other-zone behavior, names, away/return ranges, auto-off (5–120 minutes), always-on, and experimental presence auto-on with a daily time window. Solo combines bed sensors but manual zone controls remain available.
- Sleep stages exposes ordered AND-condition rules, metrics/operators, default presets, fallback stage, signal bounds, low-quality alternatives, smoothing and forbidden transitions. Preview supports last night/seven nights before save. Rule editor opened without saving a change.
- Updates shows demo commit `47034d4` (built October 22), main/dev channels and update checks. No update invoked.
- Biometric calibration distinguishes saved, requested and processor-acknowledged profiles. Controls include HR tracking tolerance/history/minimum peak score, breathing interval bounds, HRV minimum windows and inherited stage overrides. Evaluation uses frozen tuning/validation/holdout nights; processor adoption is not implied by saving.
- References accepts CSV/JSON up to 2 MiB / 2,000 records, with record key, metric/value/unit and timestamps or intervals, sleeper identity and source. Previewed one synthetic heart-rate record, accepted with no conflicts; did not save/import it. Coverage extent is distinct from continuous coverage; incompatible HRV definitions and conflicting stages remain unscorable.
- Profile review validates a candidate before an explicit save-without-apply step. Reviewed unchanged defaults; did not save.
- Backtests supports up to 60 nights and 20 references with immutable input freezes. Inspected synthetic session 41500: stored vitals/stages available, raw signal replay unavailable, provenance unknown and no overlapping references. No dataset created.
- Observations prepares future bounded comparison plans, followed by separate explicit activation/scheduling. Inspected a missing-readings demo template; no plan activated.

## Curve-library reconciliation

The live demo has the newer owned schedule library, absent from the local fork at this inspection. Upstream dev `47034d44b9dd113890ca05e3ba6af38a29978e1d` adds `days`, `active`, `endAction` to curve templates, atomic `PUT /curve-templates` and `POST /curve-templates/active`. Active curves claim side/day pairs; activating or editing one moves overlapping claims with a review prompt. No-day curves save inactive. Names and notes are retained. The native implementation must support these semantics and preserve the existing legacy schedule/overnight routine integration.

Opened New curve and applied Balanced in the public demo without saving. Editor exposes name, side/day selection, active state, bedtime/wake rebasing, temperature range, three presets, AI draft, point editing/deletion/addition, notes and end action. The generated preview includes pre-bed and post-wake points; actual power bounds follow first/last points.

## Sleep detail and Biometrics audit — October 25

- Nights provides time correction/deletion, four aligned vital/movement lanes, zoom/pan/range selection, Apple Watch reference overlays and raw exports. An after-midnight bedtime belongs to the prior noon-to-noon night in Biometrics. Opened the sleep-time editor without changing a demo record.
- Biometrics has Night/Week/Month, through-date/earlier/later/latest, side selection, sessions that focus the chart, source-aware summaries, original-reading raw log with sorting/search/paging and upload of Apple Watch reference data. Exercised zoom from 1× to 2× and opened Raw log.
- Raw data includes separate CSV actions, aggregate export, archive download and all-controller RAW files with size/date/download/delete. The active newest RAW file cannot be deleted. Archive includes matching RAW files and a **full** biometrics database, so native wording must not describe it as only the selected side/week.
- Watch upload accepts ZIP/XML up to 512 MiB, last 7/30/90 days, and explicitly explains that the whole export is sent to the Pod. Opened this editor but selected/uploaded no user file. Dev `47034d44…` returns HR, breathing, HRV and stage counts; current coordinated Core at the inspected source only imports HR and stages. Native capability behavior and Core coordination must account for this gap.
- Source provenance is material: current Pod HRV is `window_ibi_variability_v1`, not RMSSD or SDNN. Charts split gaps/processing runs, and mixed definitions do not get one aggregate value. iOS now preserves this metadata and does not write unknown/IBI measurements into HealthKit's SDNN type.
# Sleep-stage settings follow-up (2026-10-25)

Reviewed the live Settings → Sleep stages screen and opened a rule condition editor. It exposes per-side model upload/library/activation, rule presets (Default, Movement only, HRV first), quick wake/deep thresholds, ordered rules and compound conditions, fallback stage, outlier limits/spike cutoff, low-signal rules, smoothing and transition pairs, latest/7-night preview, Watch agreement/kappa and changes/revert. A save can remain pending processor adoption; the current Core route distinguishes desired and acknowledged generations. No rule was saved or model uploaded during inspection.

Primary owning sources: `sleepypod-core/src/components/settings/SleepStageRules.tsx`, `SleepStageRows.tsx`, `SleepStagePreview.tsx`, `sleepStageEditing.ts`, `src/lib/sleep-stage-rules.ts`, `src/server/routers/sleepStages.ts`, and `modules/common/biometrics/manifest.v1.json`. Current classifier routes are GET/PUT `/sleep-stages/classifier` and POST `/sleep-stages/classifier/preview`. The native protocol already reads `/biometrics/sleep-stages` for comparison, while the main nightly summary currently uses the local analyzer; reconcile those sources in the next stage-control slice.

Biometrics source audit also confirmed five-minute movement buckets (`/biometrics/movement/buckets`) count postural-change epochs within recorded in-bed windows and normalize to events/hour. Occupancy `/biometrics/occupancy`, health `/health/data-path` and the latest vital jointly determine the stalled-pipeline notice; unavailable/suspect occupancy must not imply a stall.
