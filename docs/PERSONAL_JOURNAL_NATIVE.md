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

## Private habit comparisons

The optional “Habits and feeling too warm” disclosure follows the ordinary check-in
controls. It extends the same native Form and Theme; this is a Read task inside an
Operate surface. The two required morning answers stay primary. Date pickers and
one explicit comparison action read up to 90 inclusive wake dates. Results use only
saved personal entries, so a failed comparison never discards the current draft.

Lead each result with source, selected range and generation time. Retained time
zones remain separate. Each finding shows both usable/too-warm counts and excluded
entries before its percentage-point difference. Five dates in each group is only
a display threshold. Definitions, exclusions, empty/insufficient states and the
association/confounding explanation remain available without opening diagnostics.
No habit recommendation, temperature action or training permission is inferred.

Core advertises `personalJournalPatterns` separately. The native client pins the
personal credential, account and revisions, checks access before and after loading,
rejects broader projections and inconsistent counts, and clears findings on query
changes, closing, saving, account changes and backgrounding. The journal and
comparison operations have separate generations. Failed comparison reads preserve
unsaved input; late results cannot restore withdrawn content.

The synthetic fixture `personal-journal-patterns-v1.json` was generated with Core's
actual `personalJournalPatterns` function and validated with its response schema at
`5accd5b047ead1b6233e77d33689a01f3198fb1f` (merged main `e9430aea`). It is not user
sleep data. Review captures must include phone/iPad, normal/dark/largest text,
results, definitions, empty/insufficient/error/loading, and iPad landscape. No
new art, comp or design-system replacement is in scope.

### Comparison validation

The full app/framework suite passes 1,472 tests with nine existing live-service
skips. Twenty-one focused contract, transport and state checks cover strict Core
projections, inclusive calendar ranges, inconsistent aggregates, account changes,
revoked access, capability withdrawal, discarded late replies and preservation
of unsaved check-ins after a failed comparison.

The initial simulator runs exposed a Form button consuming the definitions action
and a test querying the loading indicator as the wrong accessibility type. The
button uses its own borderless action and the test queries the native activity
indicator. The independent design review then found an expanded iPad result
caveat truncating at the largest Dynamic Type size. The whole result block now keeps its intrinsic
vertical size, so both group counts and caveats wrap when definitions expand.
The independent reviewer scored the single material finding resolved in the
second correction verdict. Both phone and iPad have passing evidence for all four
scenarios on the final source, across split runs. The affected phone scenarios
and iPad largest-text/landscape scenario passed after restarting only their
simulators; earlier gesture-synthesis timeouts remain retained. Visual captures,
not accessibility-label existence alone, verify the complete wording.

No user data is present in fixtures or captures. Hosted checks, TestFlight and live
personal-account behavior remain separate from local source/simulator evidence.
