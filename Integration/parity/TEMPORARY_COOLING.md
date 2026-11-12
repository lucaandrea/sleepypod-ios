# Temporary cooling on Tonight

Extend the existing native Tonight surface with the same bounded physical-zone
request as Core. The user reviews the target and latest return time, starts once,
and can cancel from the same location. The layout inherits native typography,
semantic colors, ordinary buttons and the current Tonight composition. No new
visual identity or system tokens are introduced.

Core owns the 20-minute lease, safety checks and return. The phone never schedules
a hardware command for later. Connection loss retains the original request in the
owner-specific command ledger; “Check last request” only reads that receipt. A
newer manual change, Stop or changed arrangement prevents an obsolete return.

The workspace checks connection ownership, physical side and preview freshness
again after the capabilities request. Its view withdraws stale proposals and
invalidates pending presentation on navigation, backgrounding or side change.
Old controllers show unavailable; ordinary demo mode makes no hardware requests.
An explicit DEBUG UI-test fixture has no network transport.

The shared command contract strictly includes the cooling UUID, expected scope,
current target and reviewed deadline. The source-generated fixture is produced by
`Integration/FixtureGenerators/generate-temporary-cooling.ts` against a clean Core
revision and tests actual ready, active, waiting, unknown, cancelled and unavailable
responses. It uses a migrated in-memory database and an inert hardware adapter.

Validation must distinguish model/transport tests, phone/tablet renders, large-text
navigation, hosted CI, TestFlight and actual Pod qualification. No physical cooling
or live routine behavior is asserted by a simulation or a network acknowledgment.

## Validation receipt — 10 November 2026

Core PR 90 passed its hosted lint, TypeScript, unit, browser and build gates and
merged as `a6f0798e`. Its generated contract fixture remains pinned to the reviewed
Core authority revision `9baa9ab`. Native verification is independent:

- The complete signed iPhone unit suite passed 1,256 tests with nine skips before
  the pending-state refinement. The focused suite now passes 14 tests, covering
  ownership/side changes, expiry during capabilities, held cancellation and
  same-request receipt recovery.
- Settled review/start/cancel and lost-reply flows passed on iPhone and iPad,
  including maximum Dynamic Type. The corrected pending flow passed on both
  device classes with explicitly held 20-second replies. The final iPad run
  includes all three UI tests and all 14 focused model tests.
- Early pending-state UI checks treated a read-only label as a tappable control;
  those failures are retained. The final accessible progress row and test
  observation use separate text and spinner semantics.
- Scoped strict SwiftLint and project/source checks pass. Hosted UI checks use
  a dedicated cooling group on both devices; live hardware and TestFlight
  distribution remain pending.

The operation-specific progress retains the reviewed zone, target and expiry
while sending. Refreshing and receipt-checking are separate states. Neither a
spinner nor an acknowledged response asserts physical cooling.

Independent native finish review returned `ship` for the sole material fix:
operation-specific pending feedback. The reviewer checked all eight corrected
phone/tablet progress captures. The verdict covers that fix and the retained
incumbent design, not physical Pod or TestFlight behavior.
