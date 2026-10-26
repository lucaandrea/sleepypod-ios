# Reference measurement parity — source audit

2026-10-25. Native reference workflow is implemented and locally validated; wider biometric parity remains in progress. Core inspected at b5e56063c4a8c6462098446c84859a5e301a056c. Backtest overlays remain part of the separately unfinished Backtest audit.

Sources read: CalibrationReferences.tsx, ReferenceLibrary.tsx, references/contracts.ts, references/parse.ts, references/store.ts, biometricTuning.ts reference routes, normalize-core.ts, normalize.ts, time.ts, ReferenceTimeSpan.tsx and ReferenceOverlay.tsx.

The web supports CSV or JSON text import, a sleeper identifier and source, a server preview, explicit acceptance when rejected rows will be omitted, immutable correction revisions, paged library and exact normalized measurement inspection, and explicit source deletion. All of these belong under the existing native Biometric calibration workspace without changing its Sleepypod presentation.

## Contracts and effect boundaries

- POST biometric-tuning/references/preview: side, subjectId (1–200), source (1–120), optional timePolicy, rows (1–2000 arbitrary JSON rows). Default timePolicy.disambiguation is reject. Preview returns contentHash, adapterVersion, exact mapping/time policy, received/accepted/rejected/duplicates/unscorable/conflicts, nullable span, metric names, rejection counts/examples and warnings.
- POST references/commit: import, previewHash, acceptRejectedRows, optional supersedesImportId. Response is the descriptor plus alreadyImported. Bind the exact reviewed import and hash. Any edit invalidates preview and partial-row acknowledgement. A saved import is not evidence of validation. Preview/commit never accepts a source URL or executes content.
- Server commit recalculates the preview hash, rejects unacknowledged rejected rows and zero accepted rows, and deduplicates a still-available exact contentHash plus superseded parent. There is no separate idempotency key. Retain exact commit intent on unknown results; explicit retry uses the same import/hash/parent. A later deletion can remove the deduplication target, so do not blindly retry after inspecting a deleted result.
- Corrections require the same source/side/subject and the latest available revision; earlier revisions and frozen datasets remain unchanged. Freeze the corrected parent's UUID/mapping, and preserve conflict errors rather than silently selecting a new parent.
- GET references?side[&beforeCreatedAtMs&beforeId]: paired cursor, 50-row pages. Descriptor has UUID/family/revision/supersedes, complete summary, createdAtMs/deletedAtMs, available. Deleted descriptors remain visible.
- GET references/{uuid}; GET references/{uuid}/measurements?afterId=0&limit=100: measurement pages, nextCursor nullable; exact UTC timestamps, values/stages, units, temporal kind, aggregation, window/quality, scorable/exclusions and original row. Deleted source reads reject. No interpolation.
- DELETE references/{uuid}: returns exact id/deletedAtMs; repeated deletion is idempotent. Confirm with source/sleeper/revision and explain that frozen dataset copies are separate. Unknown results require readback of this exact descriptor, not an optimistic deleted state.

## Parser parity

Maximum UTF-8 text size is 2 MiB. JSON must be an array of at most 2000 rows; import requires at least one. CSV supports a BOM, quoted cells, escaped double quotes, embedded newlines, CR/LF/CRLF, exact unique documented headers, no extra data after closing quotes, and matching row width. Empty cells are omitted. Only timestampMs/startMs/endMs/windowMs/quality/value use the documented finite decimal/exponent conversion; stage strings stay strings. No formula evaluation, URL reads, archive expansion, or file-path interpretation. Native file picking can supplement text entry while applying these same limits.

Allowed metrics: heart_rate, breathing_rate, window_ibi_variability_v1, hrv_rmssd, hrv_sdnn, hrv_unknown, sleep_stages. Allowed stage values: wake/light/deep/rem/asleep/in_bed/unknown. Accepted measurements can remain unscorable, including incompatible HRV definitions. Normalization depth/node limits, time ambiguity, unit conversion and overlapping intervals are documented below.

## Planned validation

Use literal Core-normalized fixtures and route/body assertions; test parser edge cases and byte/row limits; draft edits invalidate preview; correction mapping stays fixed; unknown commit/delete results cannot create optimistic success; pagination retains exact cursors. Exercise native import/review/library/correction/deletion confirmation in demo on phone, iPad and accessibility text. Do not use the owner's actual health data or mutate a live Pod for tests.

## Normalization and display inspection

Also read normalize-core.ts, normalize.ts, time.ts, ReferenceTimeSpan.tsx and ReferenceOverlay.tsx. Server normalization stays authoritative: reject depth over 12/nodes over 100000/nonfinite JSON; validate a single point or interval representation, 24-hour interval maximum, exact subject mapping and metric/aggregation semantics. Unit conversion supports HR bpm/beats-min/Hz, breathing breaths-min/br-min/Hz and variability ms/s. Unknown HRV and mismatched five-minute window-index data remain excluded. Conflicting identical record keys reject all conflicting rows; exact duplicates count once. Overlapping distinct stage labels are retained but both excluded. Generic asleep/in-bed/unknown never become light.

Timestamps require 2001–2100-range Unix milliseconds or strict ISO with seconds. Without an offset, explicit time policy is required. DST gaps reject, overlaps default reject, and explicit offsets must match a supplied timezone. The web input omits the optional policy UI and asks for offset-bearing timestamps. The native initial import should do the same; do not guess a phone timezone. A server preview's interpretation is part of its immutable content hash.

Summary spans use Pod timezone/clock and say first-to-last extent, not continuous coverage. Normalized row inspection uses exact ISO UTC. ReferenceOverlay belongs to Backtests: it verifies job/content/cohort/metric/page/clock identities, plots only compatible visible pages, adds the frozen clock offset to recomputed readings, leaves reference times fixed, and adds no scores or new matches. Defer implementing this overlay until the Backtest report contract is audited.

## Native implementation

References now sits in the existing Sleepypod Biometric calibration navigation. It supports bounded CSV/JSON text and file input, fixed correction mapping, server preview, explicit acceptance of omitted rows, immutable correction revisions, paged source library, normalized measurements with original records, and confirmed source deletion. Draft changes invalidate both preview and partial-import acceptance; late preview replies cannot restore an obsolete review. Exact UTC records remain separate from Pod-timezone first-to-last summaries.

Original rows in uncertain commits are retained in protected controller/side-scoped files excluded from backup. Reopening performs no mutation. An explicit saved-result check searches the exact hash/mapping/parent and never repeats a write; a deleted match blocks retries that could recreate it. Explicit retry rechecks before sending the exact request. Deletion uses the exact descriptor and readback, including lost-response recovery. Core offers available-content deduplication rather than a permanent idempotency key for reference commits; a concurrent source deletion can still race a client read, so this is reconciliation, not an atomic server guarantee.

The demo permits only four bundled synthetic examples (two sides, original/corrected), normalized read-only by Core. It does not invent normalization or validation for arbitrary user files. Real imports use the connected controller. Five additional literal Core parser fixtures check CSV quoting, Unicode, numbers and preservation of invalid rows for preview rejection counts.

Validation completed:

- Eighteen focused checks pass: six parser cases (including five literal Core outputs), nine model/persistence/lifecycle cases and three exact REST transport cases. Coverage includes UTF-16 identifier limits, the complete 2 MiB import envelope, nonfinite/deep JSON, stale preview responses, fixed correction mapping, lost commit/delete replies, deleted-match recovery and competing local workspaces.
- Full synthetic import → preview → partial-row acceptance → saved revision → normalized measurement inspection → correction → deletion passes on iPhone, iPad and maximum Dynamic Type. Final phone contrast run: References 85.987 s and Profiles 91.165 s; final iPad: 85.469 s; maximum text: 253.953 s. The phone contrast capture predates only the additional explicit Bed side label; the iPad and maximum-text runs include it.
- Twenty-four reference captures and two additional enabled profile-action captures are retained under `previews/biometric-references/`. Visual review caught and fixed matching foreground/background colors on prominent Save/Apply buttons. Final captures show visible labels in dark and light mode, wrapping at maximum text and reachable navigation/actions.
- Strict SwiftLint, `git diff --check` and the built-product presentation guard pass. Sleepypod's cards/settings navigation remain; no retired shell or assets enter the product.

One early UI run failed because XCTest exposed both a parent and child representation of the same confirmation button. Selecting its first matching representation resolved the test ambiguity; the final full flows pass. No owner health records or live Pod mutations are used. Reference overlays inside Backtests remain in the separate unfinished report workflow.
