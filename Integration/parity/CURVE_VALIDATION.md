# Native curve library and run-once parity

Local validation on October 25, 2026. No physical Pod temperature or power changes were sent.

Implemented:

- Shared saved curves with names, notes, activation, independent left/right day claims, duplicate, edit and confirmed deletion. Active curves preview the day claims they will take from other curves before saving.
- Modern Core uses the atomic `PUT /curve-templates` contract from upstream development revision `47034d44b9dd113890ca05e3ba6af38a29978e1d`. OpenAPI discovery supports an empty library. Older controllers keep their saved-template API and explicit apply-to-selected-days flow.
- Overnight point ordering, wall-clock rebase, range rescaling, presets, point add/edit/delete and end action. Alarm schedules remain separate when a Core curve is applied.
- Run-once review with side, wake time, explicit immediate-power disclosure, validation and cancellation that resumes the recurring schedule. AI curve output opens the same review/editor workflow.
- Drafts survive save errors. Read-before-write detects stale source curves or changed day claims; it is not server-side compare-and-swap. A successful write followed by failed refresh is reported separately.
- Controls use native Sleepypod cards, typography and sheets. Largest-text clocks stack vertically and day labels use wider cells. Degree controls follow Fahrenheit/Celsius increments.

Evidence:

- `/tmp/SleepypodCurveParity2.xcresult`: 10 curve, 11 alarm and 2 schedule end-action unit tests plus 2 curve UI tests passed.
- `/tmp/SleepypodCurveLargeText.xcresult`: all 11 curve tests passed, including added range/preset boundary coverage. The editor UI passed but screenshots prompted day-label and clock layout improvements.
- `/tmp/SleepypodCurveIPad.xcresult`: both UI flows passed on iPad, including create, day-move review, point edit, run-once start/cancel and responsive editor.
- `/tmp/SleepypodCurveLargeTextFinal.xcresult`: the responsive editor passed at maximum accessibility text size after layout corrections. The requested next-alarm selector in this invocation did not match a test; its actual rerun is recorded in `ALARM_VALIDATION.md`.
- Screenshots in `previews/curves/` include iPhone, iPad and final largest-text layouts. Original iPhone captures precede the corrected primary-button contrast; iPad captures show that correction.

Still open: AI route UI coverage, legacy controller UI/error captures, precise preset-algorithm comparison, drag editing of graph points, global schedule controls and remaining Schedule audit. Demo curve-library sessions are simulated and do not update MockClient's separate compact schedule fixture. Final release validation must include the coordinated Core implementation and all remaining parity sections.
