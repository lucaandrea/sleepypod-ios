# Personal-account reports

This extends the native morning brief to authenticated household accounts.
It is an implementation record, not a distribution or live-device receipt.

## Ownership and access

Core advertises optional `personalDeviceReports` through the authenticated
household session. Absence and false keep the feature unavailable. Health import
capability and a current personal access grant are also required. The flag does
not enable Pod cloud analysis or persistent cloud consent.

An encrypted device-local archive follows Pod, household, account and sleeper
UUIDs, independently of current bed side. It contains model settings, frozen
report facts, comparison data, answers, individual sharing permissions and a
per-device monthly attempt counter. It never opens the legacy owner archive.
Provider credentials use a separate Keychain service and account/provider key.
They are non-synchronizing and available only while the device is unlocked.

Reports can be read with the last validated identity during an outage. New model
requests require a current live session. Account, credential or assignment changes,
backgrounding, protected-data loss and revocation withdraw the old workspace.
Late responses cannot resurrect a removed archive or overwrite a new revision.
Removing reports retains preferences, provider keys and attempt accounting.
Account revocation removes that account's report and key scope; explicit local
erasure clears personal storage without touching the legacy owner library.

## Request flow

1. Connect the device's own Health history and select one sleep source.
2. Choose a provider and model; Apple local inference is the default. Existing
   OpenAI, Gemini, Anthropic and Ollama clients are reused with personal keys.
3. Review the question, source, calculated evidence and destination. Each
   off-device request requires its own explicit confirmation, including a local
   server. The review expires after five minutes.
4. Reserve a cloud attempt before dispatch and recheck identity, source and
   storage both before and after the awaited request. No automatic retry occurs.
5. Render the saved brief with takeaways, comparison and expandable interpretation.
   Follow-ups use the original report's facts and require another review.

Model tests send a diagnostic prompt without Health or Pod evidence. Catalog
queries send only the chosen provider's personal key or local-server address.
A catalog listing does not establish usable model access. Attempt limits count
cloud tests and failures; they are not monetary spending limits. Report generation
does not train a temperature controller, alter schedules or dispatch bed commands.

## Optional web copy

Sharing uses a newly read personal session, a personal device credential and
`api/v1/me/reports`. It never falls back to the owner endpoint. Revision, assignment,
credential, foreground and account checks remain attached to the connection.
The person explicitly reviews the separate upload and can withdraw its web copy.
Raw Health samples and provider keys are excluded from the display document.
Other sleepers cannot read it through their app accounts; Pod administrators and
backups retain system-level access. Lost mutation replies require a read before
another action and are never automatically replayed.

## Local verification and release status

The complete native regression passes **1,678 tests, with nine existing skips**.
The combined `sleepypod-personal-reports-review-fixes-phone.xcresult` contains
those tests plus six passing UI scenarios, for **1,684 passed, nine skips**.
This includes the personal
account host, Health evidence, model catalog, report storage and sharing-denial
cases. They cover missing consent, stale grants, wrong-account storage, delayed
requests, cancellation, revocation, backgrounding, offline reading and erasure.
Strict SwiftLint reports zero violations; all seven build-support tests pass.
The unsigned physical-iOS Release build also succeeds.

All six UI scenarios pass on each iPhone and iPad simulator, including largest
Dynamic Type, fresh consent, questions, private web sharing, model settings,
failed requests, cancellation and report removal. The `review-fixes-phone` and
`review-fixes-ipad` result bundles contain the current captures. Their temporary
ciphertext, fake models and fake web transport cannot read Health or Keychain,
contact providers or control hardware. Earlier results retain the fixture
actor-isolation error, navigation-title locator mismatch and off-screen Form
discovery failure. The final screens add explicit keyboard dismissal; the tests
discover lazy Form rows by scrolling while retaining their identity assertions.

The independent review found a reversed date interval for descending input and
an unreadable provenance label at the largest Dynamic Type size. Coverage now
uses the earliest start and latest end in the source timezone; regression checks
exercise every ordering of three nights and a date boundary across timezones.
The provenance label now uses wrapping native text. Both complete six-scenario
UI runs pass again in `review-fixes-phone` and `review-fixes-ipad`, and 50 current
captures include settled evidence and provenance states. The corrected Release
build and strict lint pass. The independent follow-up review resolved both
reported findings and returned a ship verdict for those fixes. Its evidence
is limited to source and simulator captures.

Core [PR 135](https://github.com/lucaandrea/sleepypod-core/pull/135) passed all
seven hosted checks and merged as `7ff28bdd32f105e002b7442da0eb4f6dff15cabb`.
Its tree `20138c94e639e345de5545a62ebaff1d6d4a722a` equals the tested head.
This advertises the optional personal-device-report capability and does not
enable server cloud analysis or persistent cloud-sharing consent.

Native hosted checks, TestFlight, Pod installation and actual two-account
acceptance remain pending. No live account, phone,
routine, hardware setting or provider request was changed by these tests.
