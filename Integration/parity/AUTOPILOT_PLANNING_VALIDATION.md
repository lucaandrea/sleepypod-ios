# Autopilot night planning and replay parity

Implemented and locally validated. This extends native rules/diagnostics (PR #2) and does not establish full-app parity or a new TestFlight build.

## Implemented

- Saved-rule summaries read Core’s cached five-night results. Draft range replay supports 1–14 nights, retains null compared values, distinguishes requested and actual replay counts, and explains both-side aggregation. No automation or actuator mutation is used for replay.
- A shared night timeline combines scheduled power/targets, manual holds, possible rule windows, recorded firings and dry runs. The scrubber changes the inspection time only. Times use the Pod timezone and calendar-day/DST boundaries. Time/day conditions retain AND/OR/NOT unknown semantics; sensor conditions are never predicted.
- Combined replay chart shares temperature axes in policy mode, overlays raw/averaged readings, calculated and pre-limit setpoints, shows clamp/time-window shading and a separate firing/suppression rail. Missing samples remain gaps. Separate requested-temperature detail remains readable.
- Native capacitive contact activity uses paired channel variance with freshness tracking. Disconnect clears the previous Pod’s presence history. It does not infer calibrated body pressure or perform occupancy automation.
- Recorded pressure playback has play/pause, frame scrub, a fixed color scale for the whole night, and the strongest zone outline. Backgrounding pauses playback. Activity filters recognize Core’s `signal-unavailable` reason and retain grouped start/end times.
- DEBUG-only synthetic activity/zone fixtures enable rendered evidence. The screens label these fixtures. Normal Demo still reports no recorded controller history.

## Owning contracts

Core owner checkout `9d9e39a9fe4af4a0be913ab7005322aa22c3d1eb`, inspected 2026-10-25. Routes: GET `automations/backtest-summaries`, POST `automations/backtest-range`, existing activity/zone/tonight routes. Temporal eligibility follows the boolean semantics in `src/automation/evaluator.ts`; the preview deliberately leaves sensor-dependent comparisons unknown.

Web’s Diagnostics “halt” is the existing global kill-switch, not an additional recovery endpoint. Core’s personal comfort qualification remains enforced by the owning backend and linked native personal-comfort screen. No hardware qualification, recovery command, or occupancy activation is inferred from UI fixtures.

## Evidence

- `/tmp/SleepypodAutopilotPlanning2.xcresult`: 25 unit/transport/state tests passed, including eight new planning cases.
- `/tmp/SleepypodAutopilotPlanning3.xcresult`: 9 planning unit tests and all 7 Autopilot iPhone interaction tests passed.
- `/tmp/SleepypodAutopilotPlanningIPad.xcresult`: 9 planning unit tests and 3 iPad interactions passed (combined replay, night timeline/range and pressure playback).
- Maximum Dynamic Type: activity filtering, combined replay and pressure playback passed in `/tmp/SleepypodAutopilotPlanningAX.xcresult` and `/tmp/SleepypodAutopilotPlanningAX2.xcresult`; the Light timeline/range flow passed in `/tmp/SleepypodAutopilotPlanningAX3.xcresult`. Earlier range attempts failed because the test searched lazy Form rows before scrolling; the final test reveals both the button and result. Rendered screenshots were reviewed.
- Strict SwiftLint, the native-presentation guard and `git diff --check` passed. The iPhone text setting was restored to Large.
- Selected screenshots are in `previews/autopilot-planning/`: normal iPhone/iPad timeline, maximum-text combined chart, pressure replay and Light timeline/range.
- Initial PR #2 CI hit an Xcode 26.6 Swift 6.3.3 IR-generation crash converting an isolated picker setter method reference. Commit `cd56a5c` uses explicit closures without changing behavior; all four CI jobs passed on that exact head. PR #2 merged at `c9a5975bf83dc853ede790afaa81ec6de178b3e7`.
- No live Pod commands were sent during these checks.
