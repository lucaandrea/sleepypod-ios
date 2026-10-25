# Adjustable base parity

Verified locally on 2026-10-25 using Xcode 27.1, iPhone 18 Pro / iOS 27 and iPad Pro 11-inch / iPadOS 27 simulators. No real bed movement was performed.

Implemented:

- Articulated mattress/frame and simple views, horizontal rotation, pinch zoom, reset and VoiceOver camera actions. Reported positions stay separate from requested previews.
- Head/feet controls, supported speeds, four presets and an explicit immediate-preset preference. Whole-bed hardware coerces requests to both sides; independently controllable hardware exposes side selection/cards and linked drafts.
- Freshness, connection, server busy/moving and angle validation gate movement. Stop bypasses an in-flight move and remains available with stale/missing position. Late movement/reconnect responses cannot replace the Stop result. HTTP errors survive polling.
- Base schedule creation, editing, pause/resume and confirmed deletion. Editors preserve complete custom angles, speed, side, days and names. Time is a Pod-timezone wall clock. Overlap validation includes paused rows and expands weekdays/weekends/both sides.
- Native Sleepypod cards, dynamic text layouts and a constrained iPad content width. The editor uses one identified sheet draft to avoid a blank first presentation.

Evidence:

- `/tmp/SleepypodBaseParity.xcresult`: 9 base unit tests and 5 connection tests passed. The first UI run exposed a blank schedule editor; repaired before the passing run below.
- `/tmp/SleepypodBaseParityUI2.xcresult`: 2 UI tests passed, covering frame/mattress, rotate/reset, presets, simulated move/Stop, simple view and schedule conflict/create/edit/pause/delete.
- `/tmp/SleepypodBaseIPad.xcresult`: responsive controls/editor test passed on iPad; captures inspected.
- `/tmp/SleepypodBaseLargeText2.xcresult`: all 9 base unit tests and the responsive UI test passed at the largest accessibility text size. Captures inspected after replacing overlapping horizontal editor rows with vertical fields.
- Saved screenshots: `previews/base/`. The earlier large-text result is superseded because visual inspection caught overlap despite its test passing.

Still required before final parity sign-off: explicit independent-side/offline native UI captures, full pinch/VoiceOver interaction checks and cross-feature regression. Real controller movement and schedule execution remain unverified; local simulation and request assertions are not hardware evidence.
