# Bed care on iPhone and iPad

The canonical [product contract](https://github.com/lucaandrea/sleepypod-core/blob/main/PRODUCT.md)
and [surface brief](https://github.com/lucaandrea/sleepypod-core/blob/main/docs/design/BED_CARE_BRIEF.md)
preserve the existing app identity and approved read-only scope.

Status → Bed care renders Core's authenticated `health/care` projection with the
same water, circulation, recording, storage and backup semantics as the web view.
The new page is read-only. Existing diagnostic destinations keep their own repair
controls and safeguards; opening care never primes, dismisses protection or restarts
services.

Each observation has its own 30-second maximum age and expiry. A failed refresh,
account change or cancelled view withdraws current claims. A delayed response from
an old connection is discarded. Source-dependent advice expires with its observation
and remains only in the dated disclosure; reconnect/recheck guidance replaces it.
The circulation row keeps incident review and directly links to protection settings.
Saved export time is explicitly not proof of a
complete download, off-Pod storage or a successful restore. The recovery disclosure
preserves a backup-first path and links to the manufacturer's model-specific help.
It cannot inspect leaks or determine maintenance-insert age.

```mermaid
flowchart LR
  Core[Authenticated care projection] --> Owner[Current owner and connection]
  Owner --> Sources[Independently expiring checks]
  Sources --> Care[Practical care screen]
  Care --> Diagnostics[Existing diagnostic destinations]
```

`Integration/FixtureGenerators/generate-bed-care.ts` creates seven synthetic cases
from Core's actual evaluator, without opening a live database or hardware transport.
The bundled example records source commit `0c05b29b`. Practice mode shifts those
synthetic timestamps together and clearly identifies itself; it never supplies a
measurement from the user's Pod. Disabled and unreadable pump-protection settings
are distinct from an enabled setting or an active block; none of them proves flow.

Validation covers source contract parity, unsupported/duplicate observations,
expiry, failed refresh, account switches and late responses. UI checks exercise
the Status entry, diagnostic links, recovery guidance and maximum text size on
iPhone/iPad. On 10 November 2026, the signed iPhone simulator run passed 1,244
tests with nine existing skips, including all native unit/model regressions and
both bed-care UI cases. The final iPad run passed both bed-care UI cases, including
maximum Dynamic Type and navigation to protection settings and storage. SwiftLint,
build-for-testing and fixture validation passed. Results are retained locally in
`/tmp/sleepypod-everyday-combined-phone.xcresult` and
`/tmp/sleepypod-bed-care-review-ipad.xcresult`; rendered captures were reviewed.

These receipts cover local iOS 27 simulators. Hosted Xcode 26.3 checks, TestFlight
distribution, physical maintenance and recovery of the user's installation remain
separate acceptance states.
