# Native alarm parity

Local validation on October 25, 2026, with Xcode 27.1 / iOS 27 simulators. No physical Pod vibration was sent.

Implemented:

- Per-side grouped alarms, create/edit/pause/delete, enabled state, weekday/weekend selections and Pod-timezone wall clocks.
- Vibration pattern/intensity/duration, explicit test and an independently available Stop. Late test results cannot replace Stop feedback; unsent other-side tests are cancelled.
- Wake temperature, smart wake window and per-alarm snooze length/taper. Controllers with older alarm schemas keep their compatible fields; schema discovery supports empty alarm lists.
- Next-alarm cards in Dial, Slider, Both and Stage layouts, with pause/edit. A paused card keeps the selected alarm visible.
- Complete Core schedule rows retained behind compact daily summaries. Field edits issue precise batch updates and preserve extra/paused alarms, power end actions and calendar day offsets. Read-before-write detects changed source rows; it is not server-side compare-and-swap.
- Errors survive recovery refresh. Failed saves keep the draft open. A successful write with a failed refresh is reported separately and requires a reload before another edit.

Evidence:

- `/tmp/SleepypodAlarmParity.xcresult`: initial 9 alarm tests plus 17 startup tests passed, with 5 live-Pod checks skipped. Two ScheduleEndAction tests also passed. UI selectors needed correction.
- `/tmp/SleepypodAlarmUI2.xcresult`: both iPhone UI tests passed, exercising create, smart wake/snooze settings, test/Stop, paused edit and delete while preserving other alarms.
- `/tmp/SleepypodAlarmIPad.xcresult`: responsive editor passed. Next-card interactions worked but the test assumed an iPhone-style tab bar; corrected.
- `/tmp/SleepypodAlarmLargeText.xcresult`: all 11 alarm unit tests, both schedule end-action tests and maximum-accessibility editor checks passed. The next-card helper could not scroll to the Toggle because its generic swipe was consumed by the temperature dial. The corrected test taps the control using native automatic scrolling; the Toggle also keeps its intrinsic size.
- `/tmp/SleepypodAlarmNextIPad.xcresult`: next-alarm pause/edit test passed on iPad after correcting the selector.
- Screenshots in `previews/alarms/` were inspected. The maximum-text editor is scrollable and the fields remain individually readable. The earlier large-text next-card capture is retained as diagnostic evidence, not final sign-off for the whole Temperature screen.

- `/tmp/SleepypodNextAlarmLargeFinal.xcresult`: next-alarm pause/edit passed at the maximum accessibility text size. Its final capture is `previews/alarms/largest-text-next-paused-final.png`.
- `/tmp/SleepypodCurveParity2.xcresult`: all 11 alarm unit tests and both schedule end-action tests passed after schema discovery was added.

The remaining layout, active-sleeper/away, empty/offline and unknown-write cases are now covered by `ALARM_CURVE_RECOVERY_AUDIT.md` on phone, iPad and maximum text. Final cross-feature release regression remains open. Hardware delivery, vibration and scheduled wake execution remain unverified.
