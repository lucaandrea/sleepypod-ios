# Tonight overview

Improvement 03 renames the temperature tab Tonight and places a read-only plan
above the existing Cards, Stage, Slider and two-side controls. The same saved
mode, automatic range and actual next alarm appear together. Existing controls,
All off, notices and editors retain their command authority.

`TonightWorkspace` expires each receipt independently after 90 seconds and rejects
wrong-side, late-owner and canceled responses. A failing read withdraws only its
own value. Personal account boundaries, owner revision, endpoint, backend, side
and scene phase invalidate the inventory. There is no command queue or write API.
The summary cannot turn a trained model into an active-controller claim.

The morning entry reads an already-saved encrypted personal report, with its
actual creation date and evidence. It performs no Health query, cloud request or
training. Demo mode never reads the owner's archive. The shared recent-session
card explicitly labels one recorded segment; whole-night recording and gaps are
available in Sleep.

Solo sleep attribution and independent thermal zones remain distinct. A matching
alarm/limit occurrence is required before showing warming time. Missing data is
not replaced with an assumed warmup interval. Network acknowledgments never prove
physical warming or vibration.

## Acceptance

- Focused state and transport tests cover freshness, owner changes, failed reads,
  independent-zone selection, matching wake occurrences and Pod-timezone mornings.
- Signed iPhone/iPad simulator checks exercise Cards and Stage, dark/light themes,
  standard and largest accessibility text, plus the Autopilot and alarm links.
- Existing temperature interactions are checked to retain Stop, notices, manual
  holds, rotation and schedule review.
- CI adds Tonight to the existing everyday-screen matrix.

Local acceptance on 10 November 2026:

- 13 focused state/transport tests passed in `sleepypod-tonight-native-final.xcresult`.
- Both Tonight UI checks passed on signed iPhone and iPad simulators (four runs),
  including standard dark Cards and accessibility-XXXL light Stage layouts.
- Three existing temperature interaction checks passed: notices/hold choices,
  schedule review and Stage gestures. Four offline library checks also passed.
- SwiftLint passed with strict mode. Phone and iPad captures were visually reviewed.

Initial UI failures are retained: an iPad tab-bar query missed the system's top
navigation, and older control tests inherited the previous side/text-size
preferences. Tests now query the destination and set their own launch preferences;
the successful reruns are `sleepypod-tonight-ipad-final.xcresult` and
`sleepypod-tonight-control-regressions.xcresult`. No production behavior was removed
to satisfy those tests.

Hosted CI, TestFlight delivery and a live Pod walkthrough remain distinct gates.
No hardware, schedules, adaptive mode or personal Health records were changed.
