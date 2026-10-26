# Complete native bedtime routines

October 26, 2026. Implemented and validated locally; no live schedules have been changed.

Core contract: `src/lib/bedtimeRoutines.ts`, `src/server/bedtimeRoutineStore.ts`, `src/server/routers/routines.ts`, at `27736f9eac59eda6366df0645a78bbb35efc85eb`. Direct authenticated `GET/POST /api/v1/routines` replaces the unavailable retired compatibility route. Settings and Schedule open Sleepypod-native cards; the existing three tabs remain unchanged.

- Read seven starting weekdays and independent sides; display Pod timezone and label morning events on the following day. New routines start paused.
- Edit complete power window/end action, bounded starting target, up to 96 enabled/paused temperature phases, optional alarm, pattern/intensity/duration, wake window, custom snooze duration/taper and notes.
- Retain exact custom snooze values. Taper shortens later snooze durations, not vibration intensity. The recurring time picker uses a fixed date to avoid phone DST changing HH:mm.
- Review complete drafts and copies before one atomic save. Every selected weekday carries its expected revision, including explicit null for a new night. An absent alarm and whole-night deletion also encode explicit null.
- Match Core's phase bounds, weekly overlap and duplicate event checks including Saturday/Sunday. Alarms may occur outside the thermal window; do not apply the retired stricter rule.
- Reject writes over unmanaged calendar schedules. Preserve the server's whole-side ownership boundary and direct the user to migrate existing schedules.
- Owner/side changes invalidate pending reads and unsent preflight saves. A lost response clears stale editing state and requires explicit reload, without replaying the POST. Persisted configuration and scheduler acknowledgement are reported separately.
- Demo data is side-isolated, disposable and never connected to hardware. Cancelling an editor or phase sheet leaves the saved routine untouched.

## Validation

The shared `Integration/Fixtures/bedtime-routine-example.json` passes Core's actual Zod schemas and whole-week validation. Ten focused logic/REST tests pass in `Routines-phone-v1`, including atomic conflict rejection, null serialization, custom snooze preservation, weekly seams, unknown writes and owner invalidation. The complete create/review/copy/cancel/delete and side-isolation flow passed on phone (`Routines-phone-v1`) and iPad (`Routines-ipad-v3`). The first iPad helper swiped outside the centered sheet; explicit scroll-view targets corrected that test issue.

The first maximum-text run (`Routines-accessibility-v4`) was stopped after identifying cramped numeric alarm fields and a non-hittable composite stepper locator. Numeric labels/values now stack above the controls, and the test interacts with the actual increment button. `Routines-accessibility-v5` passes the full flow, additionally changing snooze to 360 seconds and asserting that value remains after reopening. All nine maximum-text captures were inspected. Final phone (`Routines-phone-v6`) and iPad (`Routines-ipad-v7`) reruns pass with the same improved fields and persistence assertion. All 27 final captures are retained in `previews/routines`; phone, iPad and maximum-text layouts were reviewed. Strict SwiftLint and the compiled presentation guard pass.

No live routine was posted and no actual scheduler execution is claimed. Final combined parity, Shortcuts/history/Health mapping and release remain tracked in `PLAN.md`.
