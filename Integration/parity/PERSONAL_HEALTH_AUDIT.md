# One native Core Health writer

26 October 2026. Core export, foreground/background sync and the thirty-day Shortcut share the native `HealthSyncService`. Release remains 0.2.0 (7). Validation here uses synthetic source records and a fake Health store; it does not establish permission or successful writes on the owner's iPhone.

## Integration

- Core no longer activates the framework's legacy Health exporter or its background task. The app cancels that legacy task when launched with Core; personal Health-history reads remain available for reviewed reports. The original-server exporter stays supported for that backend.
- The Core personal Health destination opens the native Apple Health settings, with separate choices for recorded time in bed, estimated on-device stages, heart rate, recorded SDNN and respiratory rate. An existing sleep-write preference migrates into the new presence choice; explicitly deselected sleep does not become new presence consent.
- The linked Health side is visible and editable. Foreground, background and Shortcut export use this same personal side, independent of browsing the other side's controls. The existing `userDefaultSide`/`bedSide` precedence and Pod/Bonjour identity map are preserved. Endpoint-only Core connections are supported; clients freeze the endpoint before fetching.
- Core `Sync Apple Health` uses the registered native bridge and a thirty-calendar-day source window. It returns the actual count saved in that run, including a valid zero for no new eligible data. Disabled/unavailable/denied sync, a busy writer, cancellation, scope changes or partial failures cannot become a fabricated zero-success result. Partial errors include the actual saved count.

## Record integrity

- Presence samples preserve disjoint reported intervals and exits. Malformed intervals do not become one continuous occupied night. Samples distinguish `reported_pod_presence`, `on_device_stage_estimate` and `recorded_pod_vitals`; unknown HRV definitions never become SDNN.
- Presence-only export does not fetch vitals, movement or calibration. Selected stage estimation remains on-device, with model/version attribution. Existing fragment/stuck-session bounds (20 minutes through less than 16 hours) remain in place.
- Record queries are bounded and range-split. Core uses its existing complete 100-row range loader; legacy saturated weeks are split into days and saturated days split further. Different-side or malformed records fail rather than appearing as an empty successful rebuild.
- A sync freezes owner revision, linked side, preferences and model version, then checks them around asynchronous work and before writes/cleanup. Data already saved during a scope change is kept; later cleanup and receipt publication stop.
- Per-record writes precede cleanup. Missing selected quantity types retain their old samples, mark the record incomplete and prevent the broad rebuild sweep. In particular, a missing SDNN value cannot erase previous HRV or produce a complete receipt. Valid overlapping samples retain stable identifiers and monotonically increasing replacement versions.
- Receipts and errors shown in Settings belong to the current Pod and linked side. Rebuild remains an explicit operation scoped to that Pod/side and this app's samples. Earlier legacy metadata and other apps' Health records are not deleted by a guessed migration.

## Validation

- `NativeHealth-v1`: eleven new native service checks pass, plus fifteen existing lifecycle checks, three background checks, four design/Health sample regressions and five Core App Intent checks (38 total). These cover consent migration, disjoint/invalid intervals, real thirty-day counts, idempotent repeat sync, no-data/denied/demo states, partial saves, cancellation/concurrency, owner/side/consent changes, missing-SDNN preservation and wrong-side rejection. The linked-side migration regression and all eleven native checks also pass in `NativeHealth-phone-v5` (39 focused logic checks total across these runs).
- The existing fixture lifecycle suite explicitly deselects HRV for nights without recorded SDNN; its HRV-only exclusion case explicitly selects HRV. No fake provenance was added to make those fixtures qualify.
- `NativeHealth-ipad-v3`: both settings flows pass: independent consent persists after relaunch, linked-side selection updates the displayed scope, and Demo cannot authorize, sync or rebuild Health. Five rendered captures are reviewed under `previews/personal-health/ipad`.
- Earlier phone/iPad runs exposed an overstrict test footer margin, while the rendered footer was visible. The test now checks the footer against the actual scroll viewport. Both maximum Dynamic Type flows pass (`NativeHealth-AX-v4`), with five reviewed captures showing reachable consent, linked-side controls and the complete Demo footer. Both final phone flows pass (`NativeHealth-phone-v5`). All fifteen retained phone/iPad/maximum-text captures were reviewed. Final phone captures (`NativeHealth-phone-v7`, both flows passing) explicitly expand the native medium sheet before capture; a preliminary full-height assumption in v6 was corrected in the test.
- Strict lint, the native presentation guard and whitespace checks pass. GitHub CI and merge remain pending.

No synthetic samples were written to Apple Health. The fixtures do not prove real authorization, background scheduling by iOS, or a completed physical-device sync.
