# Removing a personal archived learning copy

The Saved record screen adds an explicit review before removing one archived copy
from the authenticated sleeper's Pod library. The original source, current models,
routines, backups and previously exported files remain. Source/date/hash metadata
and the Pod's removal receipt remain. This is logical content removal, not forensic
erasure or propagation of deletion through a model's source data.

The screen inherits the existing native Form, navigation, semantic type and theme.
It shows the specific record, the effect and its limits, separate Remove/Keep
choices, and a confirmed receipt or an unresolved result. Older controllers retain
read/export access without a removal control.

## Contract and recovery

- Capability: `personalLearningRemoval`, in addition to `personalLearningArchive`.
- POST `/api/v1/me/learning/records/:recordId/remove` sends the UUID request, record,
  archive, current session/assignment revisions, reviewed content hash and explicit
  confirmation. It reuses the authenticated, identity-pinned personal transport.
- GET `/api/v1/me/learning/requests/:requestId` checks the existing receipt. A null
  receipt remains unknown. A mismatched account, copy, hash, outcome or timestamp
  is never presented as successful removal.
- Every operation checks current access before and after its response. Private
  content is hidden before a POST can be delivered. Lost responses can only lead
  to receipt reads; no automatic POST replay or duplicate Confirm action exists.
- Backgrounding, navigation cancellation, credential/account changes and revocation
  discard the in-memory body and pending display state. A later visit reads current
  library state; it cannot resume an old mutation. Request metadata is not persisted.
- Removal never calls the bed control APIs. A network acknowledgment proves saved
  content removal only; it says nothing about thermal, vibration or base behavior.

Controller counterpart: Core PR 118, `learningRemovalContract.ts`,
`learningRemovalApi.ts` and the transactional `PersonalLearningLibrary.remove`.
PR 118 merged after all seven hosted checks as
`9a7b8dd9a9737edc103cdf1348e9a7ba1c13612a`; its tree exactly matches tested
`4c30bcc823fcdff9cba1c0ea788002135b0c10dd`. Main packaging, release, OpenAPI,
reference and back-merge workflows passed. This is not a live Pod deployment.

## Validation

The application regression passed 1,372 tests with nine existing skips, including
eleven new contract/workspace/transport tests. Contract and workspace tests cover exact scope,
review/cancel, single dispatch, missing/lost/mismatched receipts, unavailable capability,
preflight revocation and invalidation while a response is pending. Transport tests
verify the bounded, authenticated POST and receipt-only GET. Native UI checks cover
review, cancellation, confirmed/redacted reading, uncertain recovery, a pending
request with disabled controls, unavailable controllers, largest text and both
device classes. Five removal scenarios passed on iPhone; all six passed on iPad,
including landscape (the only phone skip). The existing library/export suite also
passed five phone and six tablet scenarios, with the same landscape-only skip.

Final screenshots use explicit portrait orientation plus the separate iPad
landscape test. The first UI run exposed a test helper waiting for an off-screen
virtualized row before scrolling; the corrected helper reaches the actual row
before asserting its touch target and tapping. Render inspection also restored
the existing Theme red to the destructive action. The final build and strict
production-source SwiftLint passed. The independent reviewer inspected all 28 final
original captures, verified their hashes and all eight supplied source hashes, and
returned `ship` with no material fixes for this native extension. That verdict is
limited to the supplied source/simulator evidence; the reviewer did not rerun tests.

Hosted integration, TestFlight distribution and live personal-account acceptance
remain separate. This change does not activate the two-sleeper arrangement or
complete personal model/report enrollment.
