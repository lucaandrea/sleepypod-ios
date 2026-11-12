# Morning report sharing — work in progress

Approved item 12 needs the browser and native app to render the same saved facts,
comparison, interpretation and dated answers. The iPhone morning brief now links
to a Web copy screen with explicit sharing consent, fresh status and withdrawal.
The matching Core browser reader is implemented and in review. Personal-account
report/Health enrollment remains in progress.

## Private export and transport

`MorningReportTransfer.document` explicitly exports a version-1 display document.
It does not serialize the whole intelligence archive. Provider keys, raw Health
samples and other reports are absent. Every date uses integer Unix milliseconds;
the existing private archive retains its Foundation reference-date encoding.
Missing comparison days are explicit nulls and carry a `recorded_sleep_minutes`
metric tag. The shared native/Core fixture includes a real 25-hour DST day.

The encoder checks identity uniqueness, facts, bounds, clocks and dated answers
before returning data. Its complete UTF-8 document is capped at 384 KiB. The shared
fixture includes a missing day and a dated follow-up. Core reads the same JSON with
its real report parser and comparison validator.

`MorningReportHTTPClient` only reads, shares and withdraws one report through fixed
owner or personal REST paths. A supplied identity pins the reply's installation or
Pod/household/account/sleeper and revisions. Cookies, URL caches, credential stores
and redirects are disabled. Streamed responses are bounded; report identity,
revision, deletion state and clocks are checked before delivery. Only an explicit
JSON `not_found` response to a GET means that the report has not been shared. Failed
mutations are never replayed automatically, and server debug text is not displayed.

## Explicit owner flow

The host verifies its current installation through the existing authenticated
challenge endpoint, checks any saved route profile, and pins the credential,
logical owner and account boundary throughout the operation. The sharing screen
starts with a read. It requires separate consent to upload the selected report and
names the actual Pod address and owner-key access. It cannot create a public link.

An uncertain result requires a fresh read before another upload. The user can also
withdraw an uncertain initial upload; the server retains a deletion record so a
late upload cannot recreate it. Withdrawal confirms the live Pod copy's removal,
not deletion of the iPhone archive or existing backups. Original evidence and
existing answers cannot be rewritten. Additional answers can extend a matching
prefix; a newer web copy is shown without replacing its answers with an older
phone copy. The server is the durable receipt store; reopening always reconciles
through a read, even after an app restart.

Leaving the screen, device lock, or a changed connection/account clears displayed
sharing state. Late replies cannot restore it. Personal-account UI currently stays
unavailable until its private report/Health enrollment is complete; the tested
personal wire protocol does not expose owner reports or provide an owner fallback.

## Validation and release

Local signed simulator tests for the exporter, transport and workspace passed
17 test functions / 23 parameterized executions with zero failures or skips. They
cover prefix-only answer updates, uncertain upload recovery, lock/account changes,
withdrawal, malformed identities and clocks, streamed limits and no automatic
retries. Two earlier test builds failed for missing `try` and Swift 6 capture rules
in the new test fixtures; the repaired suite passed. Strict focused SwiftLint passes.

The complete native model/application regression passed 1,521 tests (1,527
parameterized executions), with nine existing skips and no failures. After the
accessibility button correction, the final build and strict focused lint passed;
all five UI tests passed on each signed iPhone and iPad simulator. These cover
explicit consent, uncertain-request read recovery, withdrawal, unavailable service,
and answer updates at the largest accessibility text size. Forty-eight final
screenshots cover the normal/dark and largest-text/light states. The independent
reviewer inspected every final original and returned `ship`, scoring the one
large-text button finding resolved. The ordinary extension retains the incumbent
Theme, system text styles, navigation and consent behavior; no design-system file
was replaced.

Hosted validation, distribution and live delivery remain separate. The UI examples
use only in-memory synthetic reports and cannot access Health, Keychain, the Pod,
the intelligence archive or AI services. Physical VoiceOver and keyboard behavior
have not been established by these simulator tests.

Remaining: browser reader review and browser questions; personal report/Health enrollment and
sharing; reviewed owner-history transfer; native answers from a newer web copy;
hosted and physical release checks. A saved report never changes a temperature,
alarm, arrangement or adaptation mode.
