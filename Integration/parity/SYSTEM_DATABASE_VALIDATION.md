# Native System database tools

Implemented and locally validated on 2026-10-25; owner CI and merge recorded below. This is a System subfeature, not complete native web parity or a new TestFlight release.

## Coverage

The existing Status screen now links to database inventory, integrity and migrations, table sizes/WAL/free pages, retention and growth projections, occupied-hour write gaps, and a read-only row browser. Exact-column filters preserve empty strings and escaped query values. Pages are newest-first, with previous/next navigation. CSV copy/export covers the current page and neutralizes spreadsheet formulas in text cells; nulls and numeric values retain their types.

The controller’s online backup is streamed to a protected temporary file using the configured owner connection. Non-2xx/incorrect content types are rejected, cancellation and failed transfers remove temporary staging, and leaving the screen removes the exported local copy. A user explicitly chooses where to save/share it. Demo supplies labeled synthetic inventory/rows; it never claims to have database files, a completed integrity check or a downloadable backup.

Rows clear on refresh/filter/page changes. Revision checks prevent late responses from replacing a newer query. Failed requests preserve a labeled prior inventory but never expose old rows as a new filter result. Missing backup/integrity times and unavailable disk space remain unknown.

Status run-once cancellation now reports failures, retains the active banner until success and disables duplicate taps. It calls cancellation without an extra power-off: Core’s `/run-once/cancel` resumes the recurring schedule itself.

## Source contracts

Inspected Core `src/server/routers/databases.ts`, `src/components/System/DatabasesTab.tsx`, `databasesLogic.ts`, and `app/api/db-backup/route.ts`, plus `src/server/routers/runOnce.ts`, on 2026-10-25. REST uses GET `/system/databases`, GET `/system/databases/rows`, POST `/system/databases/integrity` and GET `/api/db-backup`. The web row browser has no arbitrary deletion command; none is added to native.

## Evidence

Fresh validation after the Mac restart uses Xcode 27.1 and iOS 27 simulators. Results are retained locally under the ignored `build/parity-validation/` directory:

- `Databases-final-phone.xcresult`: 22 unit/transport tests (9 database, 2 streamed-backup, 11 existing curve regressions) and the full database iPhone interaction passed.
- `Databases-final-accessibility.xcresult`: inventory → table growth → exact filter → next page passed with the largest accessibility text size. The keyboard Search key submits the filter and dismisses the keyboard.
- `Databases-final-ipad.xcresult`: the same interaction passed on iPad in Light appearance.
- Six retained PNGs in `previews/system-databases/` show normal iPhone, largest-text iPhone and Light iPad. These are labeled synthetic records, not a live Pod database.
- Strict SwiftLint, `git diff --check`, and the compiled-source presentation guard passed. The guard verifies the retired Free Sleep UI/assets are absent.
- The streamed-backup tests use a real loopback HTTP server and synthetic bytes, not a real SQLite archive. They verify exact download bytes, backup-exclusion metadata, cleanup, HTTP 429 and wrong-content-type errors. Physical iOS file protection and restoration of a real Core archive remain unverified; the simulator does not report the file-protection attribute.
- No live database integrity/backup request or bed-control command was sent for this verification.

Owner PR/CI merge: pending publication. Complete System/settings parity and final TestFlight delivery remain in progress.
