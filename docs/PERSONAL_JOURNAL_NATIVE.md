# Personal morning check-ins

Each personal account can open its own check-in by wake date, answer restfulness
and temperature comfort, and optionally add notes and habit timing. These are
self-reports, not measured sleep or permission to train a model. Ownership follows
the account when sides change. Owner credentials and legacy side journals are not
used as a fallback.

The native editor uses the existing Household Form, Theme, navigation and journal
context controls. This is an Operate extension: two explicit ratings are the
ordinary task; habits remain optional. System pickers, Dynamic Type, light/dark
appearance and native back navigation are retained. Saved, unsaved and uncertain
states must remain distinct. Review captures must cover phone, tablet, enlarged
text, errors, deletion and a changed saved entry; no design-system replacement or
new illustration is in scope.

Drafts remain in memory and disappear when the screen is hidden or account access
changes. Opening another date reviews draft loss. Deletion needs confirmation and
does not erase existing backups. An uncertain write blocks further edits; receipt
recovery reads the latest entry without resending the write. Returning after an
interruption opens saved state rather than replaying a draft.

Core must advertise `personalJournal` for this personal account. Missing capability
means unavailable. Requests and responses pin the account, sleeper and session /
assignment revisions; private content is rechecked before and after reads and
writes. Access is checked while the editor remains open. Redirects, oversized
responses and broader response projections are rejected.

Source implementation, simulator verification, TestFlight delivery and live
two-account qualification are separate acceptance states. This feature cannot
change schedules, temperature, base position or model activation.


## Validation on November 11, 2026

The full iOS Simulator unit suite passes: 1,314 tests passed and nine existing
skips. Thirteen targeted contract, transport and state tests cover account scope,
strict response shape, timezone/tombstone consistency, explicit choices,
optional-context validation, uncertain delivery without resend, newer saved
entries, deletion, background interruption and revoked access. The frozen Core
fixture was checked against Core's actual journal response schemas.

Four UI scenarios pass on both iPhone and iPad simulators (iOS 27.2): editing and
reviewed deletion, optional context with the largest accessibility text size and
dark appearance, unavailable/error recovery, and uncertain-save reconciliation
followed by background privacy clearing. iPad landscape was inspected too.
Initial failures exposed hidden cancellation and inherited accessibility
identifiers; both were repaired. Later failures were test scroll direction errors;
the original behavioral assertions remain. Logs retain the initial failures and
final passes separately.

These are source and simulator results. This change has not been delivered through
TestFlight, activated on the live Pod, or qualified with two actual accounts.
