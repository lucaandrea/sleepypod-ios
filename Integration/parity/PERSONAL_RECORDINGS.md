# Personal recording history

Native personal accounts read the frozen Core75 contract through `GET /api/v1/me/sleep` and `GET /api/v1/me/sleep/:id`. The account capability `personalHistory` must be enabled; the client never falls back to installation-owner or side history APIs. This change does not enable that capability on a live Pod or introduce ingestion, assignment activation, Health export or a release-version change.

## Contract pin

- Core merge: `db9cfb0194902c13a3f5c58cb03d954311b2f984` (PR75).
- Shared fixture: `Integration/Fixtures/personal-history-v1.json`.
- SHA256: `2fd3c9df02a4acc51aa2525d5890746c3659ffae2422c670615001495a0a4166`.

Every request uses the pinned personal credential and sleeper header. Reads revalidate the full session, including household and assignment revisions. Page and detail envelopes must match every scope field; response keys, payload interpretations and numeric ranges are validated. Redirects, shared caches and cookies are disabled. Cursor strings are passed unchanged, including escaped plus characters for the server's URLSearchParams parser.

## Screen behavior

Personal account → Your recordings shows presence, vitals or movement for rolling 7/30/90-day ranges. Records retain their complete original interval and recorded side. No presence values are clipped or prorated, and no sleep score or sleep stages are inferred. Null vitals remain unavailable; Pod HRV retains its own metric. Times use the device's named time zone.

A detail read reauthorizes and verifies the selected record against the page snapshot. Pagination retains the original query and attribution revision. A stale cursor, invalid response, interrupted body or mismatched record discards the accumulated private snapshot; Refresh starts again. Backgrounding, account changes and revocation clear bodies. Nothing is stored in defaults, the credential vault, command recovery or Health. Stop uses an independent transport and remains available while history reads are pending.

## Validation

Contract tests cover the frozen fixture, complete overlaps, strict scopes/keys, nullable measurements and bounds. Workspace tests cover pagination, cursor loops, changed attribution, revocation, background/identity changes during reads, detail mismatch, empty state, parent lifecycle, no persistence and Stop independence. Transport tests cover fixed GET routes, opaque cursor encoding, capability rejection, HTTP failures, incomplete bodies and no retry/fallback.

Five synthetic UI scenarios cover presence and overlapping details, null vitals and movement, stale pagination recovery, maximum Dynamic Type records and empty state and disabled capability. The focused workflow runs on iPhone and iPad; it retains screenshots and xcresult bundles. Synthetic results do not qualify live ingestion or physical-device acceptance.

Local execution was initially blocked because Xcode updated from 27.1 to 27.2 while its CoreSimulator component remained older. Final validation receipts are recorded in the pull request. The separate Appearance first-tap issue remains unresolved; no Appearance implementation or assertion was changed for this feature. App version remains 0.4.2 (15).
