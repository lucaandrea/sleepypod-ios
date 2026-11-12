# Personal quiet time

The personal-account screen now exposes the Core quiet API merged in Core PR 124.
It shows the current person's request separately from the shared expiry, which is
the latest active expiry across people. Ending one person's request cannot clear
another person's request. Available durations are 30 minutes, one, two or eight
hours; changing the duration begins it from the time of the explicit save.

## Command and identity boundaries

Only personal device credentials are used. The additive `householdQuiet`
capability defaults unavailable when omitted. Each read and write validates the
complete account/session/assignment context. Endpoints use the original verified
origin, no cookies or cache, a bounded response and no redirected credentials.
JSON projections reject extra fields and malformed scope, timestamps or receipts.

Mutations use a fresh read and the person's revision before a single expiring
POST. An uncertain result blocks another change. Recovery reads the request's
receipt and current state; it never resends. An absent receipt clears the pending
state only after a fresh server clock passes the original submission deadline.
Automatic refresh continues only for a current successful read. A failed read or
uncertain save leaves stable recovery controls until the person explicitly checks.
Observed quiet status expires after 15 seconds, checked against both wall clock
and monotonic elapsed time. Expired quiet intervals do not appear active.

Backgrounding hides readings and cancels their publication while retaining the
uncertain request reference in memory for the same account. A transient parent
refresh failure retains it too. A changed credential, identity or revision,
revocation, sign-out or confirmed maintenance transition disposes the old
workspace. Maintenance checks with an unknown result disable controls; they do
not silently clear an unresolved receipt. Relaunch performs fresh reads and
never queues or replays a quiet mutation.

## Visible scope

The screen explains that new base motion and connected bedtime-light, shade and
purifier routines are subject to quiet. Temperature schedules, wake alarms,
audio and other home routines continue. A saved receipt confirms controller
state, not delivery to every accessory or physical stillness. Existing base
motion requires Stop. The feature does not identify who is physically in bed,
create a guest arrangement, or implement temporary side swaps.

## Verification record — November 12, 2026

The JSON fixture is exported from the real Core API backed by migrated in-memory
stores with two synthetic accounts. It contains no personal Health data or
production credentials. The export script records the source commit.

- Contract, transport, workspace and parent-account tests cover separate quiet
  requests, explicit null clear, reply loss, clock changes, expired observations,
  revision conflict, background, account switch, revocation and maintenance.
- Signed local integration run: 46 tests passed, no failures. SwiftLint: zero
  violations. An initial UI compilation failure used the wrong `Section` overload;
  it was corrected and that failed result bundle is retained.
- The first UI runs found offscreen-row and transition timing assumptions in
  the test helper; those were corrected without dropping scenarios. An additional
  phone check exposed periodic loading flicker after an error; automatic polling
  now stops in that state and a model regression test protects the behavior.
  All five final UI scenarios pass on both phone and tablet, including disabled,
  loading, read failure, unknown save/recovery, partner preservation, Dynamic Type
  and tablet landscape. The final phone bundle also passes 26 focused model,
  transport and parent-boundary tests. All 23 named captures are retained.
- The complete signed local native unit suite passes **1,587 tests**, with **nine
  existing skips** and no failures (parameterized test executions are reported
  separately by Xcode). Results: `sleepypod-native-quiet-full-unit.xcresult`;
  UI: `sleepypod-native-quiet-phone3.xcresult` and
  `sleepypod-native-quiet-tablet3.xcresult`, retained under `/tmp` in this workspace
  session.
- An independent Impeccable review returned **ship** for this narrow native
  extension after opening all 23 captures and verifying every capture/source
  hash. It found no material fixes. Existing native Form, Theme and navigation
  conventions are preserved; no design-system file was replaced. Hosted checks
  and live delivery remain separate gates.
- No TestFlight distribution, live Pod update, household activation or home
  automation activation is established by these simulator checks.
