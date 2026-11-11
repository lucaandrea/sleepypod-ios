# Native habit context and discoveries

Mode: Operate for the morning form and Read for its comparisons. Preserve the
existing native journal, theme, side/date selection and revision-aware workflow.
This is an extension of the incumbent interface, not a replacement visual world.

## Contract and privacy

Core advertises `contextVersion: 1`. Without that capability the existing Boolean
habit controls remain. The new optional context represents Not logged, None and
Yes separately. Amounts, dates and times are optional; a blank amount is not zero.
Notes, journal details and source-separated comparisons stay in the authenticated
Pod journal. This feature does not send them to a model or issue hardware commands.

The native app independently decodes and validates Core's versioned fields and
comparison counts. `Integration/Fixtures/morning-journal-context-example.json`
is synthetic output of Core's `scripts/contracts/export-journal-context.ts`;
its `sourceCommit` identifies the producer. Health data is not embedded in it.
Legacy clients preserve detailed fields when editing the earlier fields.

## Clock and draft semantics

Journal clocks use the entry's original time zone. Wall-clock candidates are
resolved independently from the phone's zone. Nonexistent DST times are rejected;
repeated times require an earlier/later choice. The optional time control proposes
a clock only when the user adds a time, labels it for review and does not save it
until the complete check-in is submitted. Times must lie within the preceding local
calendar day or wake date and cannot be in the future.

Raw amount/time drafts survive side/date changes, errors and uncertain saves.
A new-entry time-zone race is rejected by `expectedTimeZone`; the draft remains
in its original clock until an explicit new-zone or saved-entry choice. A lost
reply is reconciled by reading the actual revision/content, never by replaying a
write. Edits made after that uncertain reply remain separate from the acknowledged
content. Account/connection changes clear the open workspace.

## Presentation and interpretation

The quick comfort/restfulness check remains first. Habit details appear only for
Yes. Bedtime, meal and stress sit in a disclosure, with native date/time controls,
plain unit labels and Dynamic Type. Quantities use explicit US standard drinks,
mg and minutes. No decorative score or nested card is introduced.

Comparisons expose both group and warm counts, excluded entries and their exact
definitions. They remain separated by physical side, journal origin and retained
zone. Five dates per group is a display threshold, not proof or a clinical sample
size. Equal displayed rates use neutral wording. Missingness, confounding and
noncausality remain visible; these findings do not change temperature.

## Validation

The generic signed simulator build passed for arm64 and x86_64. The complete
arm64 iOS 27.2 regression passed 1,314 tests with nine existing skips in
`SleepypodJournalRegression-v1.xcresult`. The focused contract/workspace/REST
suite previously passed 22 tests. It covers missingness, invalid quantities,
DST gaps/folds, quarter-hour zones, retained drafts, uncertain writes and explicit
time-zone reconciliation. The Core fixture reproduces byte-for-byte from source
`a29b0b5657db1ad6303ab7a7589bcd93f6a540a0`; PR 95 merged with an identical tree.

All five interaction scenarios passed on both signed iPhone and iPad simulators:
ordinary dark editing/comparisons, maximum-text light controls and definitions,
time-zone conflict/save, repeated-clock choice and a light validation/saved-entry
conflict. Receipts are `SleepypodJournalReview-iPhone-v9.xcresult` and
`SleepypodJournalReview-iPad-v9.xcresult`. Ten current focused unit tests also pass,
including preservation and review of complete saved habit details. The earlier
full regression above predates that final conflict-fixture regression; it is not
represented as a full run of the final source.

Visual inspection found that the standard occurrence picker clipped its choice
at maximum phone text size even though the interaction succeeded. A wrapping menu
trigger corrects that. The signed arm64/x86_64 v10 build and focused clock tests
passed again on both devices (`SleepypodJournalClock-iPhone-v10.xcresult` and
`SleepypodJournalClock-iPad-v10.xcresult`). Final visual evidence comprises 38 v9
captures plus four v10 clock captures, hashed with current sources. The parent
inspected every changed review state, including complete conflict details,
light-mode validation, large-text counts/definitions and both clock sizes.

Earlier failures remain separate: v7 rejected an inconsistent detailed/legacy
demo conflict fixture; it was corrected and covered by the added unit test. The
v8 build caught overlapping Swift accesses in that fixture, corrected before v9.
The earlier v3 visual HOLD and v9 clipped picker evidence are retained. Strict
lint, integration reconstruction, compiled presentation and whitespace checks
pass. Independent final review returned SHIP after individually inspecting all
42 final captures and verifying all 58 source/capture hashes. The prior HOLD is
preserved. Hosted iOS 26 acceptance remains open.

The personal-context workflow builds one signed bundle, verifies its exact Git
revision and Xcode version in every consumer, and runs both daytime and journal
scenarios on phone and tablet. Local YAML and shell syntax checks passed; this
does not substitute for hosted runtime acceptance.

No physical iPhone, Health permission or live Pod change is claimed here. Personal
account activation and mapping a physical side to a particular sleeper remain
separate workstreams.
