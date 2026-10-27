# Home feedback recovery — 0.3.0 (9)

This update addresses the failures reported after testing build 8 at home. It retains Sleepypod's native presentation and the existing app identity.

## Changes

- Legacy settings may omit `rebootTime`; the app keeps it absent rather than failing the whole settings response or inventing a reboot time.
- Every service included in the status total appears in a category. Nonhealthy services also appear in a separate attention card.
- Connection settings display the saved or discovered origin, explain the retained Keychain key, and allow local controllers that do not require a key.
- Overnight curves place preparation before bedtime, retain distinct settling points when the wake time changes, and keep deleted settling phases savable.
- Analysis reads complete paginated imported presence, vital and movement history, counts those sources separately, and charts original vital measurements. Historical vital samples are not relabeled as sleep sessions or model-training labels. The overview loads up to 250,000 records per archive kind; larger sources remain available through the date-filtered archive browser.
- Analysis charts scale with accessibility text and use fewer axis ticks to keep measurement labels readable.
- Apple Health sleep history is read across the available date range after existing read consent. Failed or unavailable reads remain visible. Personal model training, sleep-stage inference and Pod temperature automation are explained separately.
- Late model responses cannot replace a newer side's result. Unsupported controllers receive a readable explanation; the source badge correctly identifies a Pod model.
- The app registers its Shortcuts on launch, features next-alarm read/change/skip actions, links to its system Shortcuts library, and provides six sleep-focused workflow recipes. All 16 underlying actions remain available. Recipes do not silently create automations.

## Verification

Focused settings/status/connection and overnight-curve regressions pass. Archive tests exercise 650 bed records and a separate 1,100-vital-record source without inventing bed sessions. Health tests verify read-consent gates and distinguish failed reads from empty history. Read-only acceptance uses the actual native clients against the owner's Core controller and checks decoded settings/schedules/status, complete archive counts and six fresh bed temperatures. Credential contents and personal measurements are excluded from fixtures and this report.

The final local iPad run on iOS 27 passes **958 checks, zero failures and five explicit physical-startup skips** (963 total). It combines 954 unit/transport/live-read checks with four UI checks. The separate final iPhone UI run passes all four checks. Both sizes cover the analysis overview, maximum accessibility text, connection prefill, sleep recipes and the system Shortcuts handoff. The UI harness centers large accessibility rows and closes the iPad system Shortcuts sidebar before asserting action visibility; it still requires the next-alarm action to be hittable.

Strict SwiftLint reports zero violations across 464 files. Reproducible feature-import reconstruction and the compiled-presentation guard pass. Local result bundles are `build/parity-validation/home-feedback/final-ipad-scaled-charts.xcresult` and `scaled-charts-phone.xcresult`. Earlier failed UI attempts are retained separately and are not counted as successful suites. [PR #40](https://github.com/lucaandrea/sleepypod-ios/pull/40) is merged into main at `f87a75db46240e83ba5eddba3409f6082fd2b921`; its branch is deleted. The merged production files match the tested and archived source manifest.

Live GET checks do not establish physical vibration, scheduled wake delivery, base movement, Health writes, Home pairing, spoken Siri execution or overnight comfort qualification. Attended Pod controls remain coordinated with the backend chat. The ESP still needs its protected controller configuration over USB; its last accepted firmware already has Wi-Fi configured and Preview disabled.

```mermaid
flowchart LR
  Legacy[Legacy settings] --> Native[Sleepypod native UI]
  Core[Core history and sensors] --> Native
  Health[Permitted Apple Health reads] --> Native
  Native --> Checks[Regression and live read checks]
  Checks --> Release[0.3.0 build 9]
```

## Final signed release candidate

Xcode successfully archived and exported **0.3.0 (9)** from source `83e03fd68323fe399b4e112ddf647832f8533fa7`, including the accessibility chart follow-up. Both the local iPad suite and phone UI checks pass on that production source. The original archive was superseded before any upload and is retained separately as evidence.

- Organizer archive: `~/Library/Developer/Xcode/Archives/2026-10-26/Sleepypod-0.3.0-9-final.xcarchive`.
- Export: `build/parity-validation/Export-0.3.0-9-final/Sleepypod.ipa`, 30,170,717 bytes.
- IPA SHA-256: `764edc201852b11668fa461ba781cdb6ed0e840aa45123ca3a8dadf1d3fcb418`.
- App and Watch pass strict signature verification, have matching build/version identities and distribution profiles, and disable development debugging. The app retains HealthKit and HomeKit entitlements.
- App, Watch, framework and SDK privacy manifests and license notices are bundled. App Intents metadata contains 16 actions and 10 featured Shortcuts. Compiled release sources exclude the retired Free Sleep presentation.

Organizer requires its Apple account to be signed in again before upload. Safari remains signed into App Store Connect, where build 8 is the latest verified upload. Build 9 has not been delivered to TestFlight. The owner has been asked to complete the Xcode sign-in dialog; group/tester assignment follows successful upload and processing.

The backend chat independently verified that the deployed Core web app and existing physical iPhone app receive live data, and that the weekday routine is saved. That does not establish installation or physical behavior of this new build. Actual vibration, scheduled wake delivery and presence qualification remain open; Autopilot remains off pending qualification. The ESP still requires USB provisioning of the protected Core connection.

## Remote verification and merge

[CI run 40429394056](https://github.com/lucaandrea/sleepypod-ios/actions/runs/40429394056) completed successfully on source `83e03fd68323fe399b4e112ddf647832f8533fa7`. All four jobs—build, lint, contract-test and done—passed. Its downloaded iOS 26.2 x86_64 result reports **951 passed, zero failed and eight explicit skips**, 959 total. Five skips are physical startup checks; three are the opt-in private-Pod read checks that ran successfully in the local suite. The separate API contract job also passed.

The final evidence update changes this release record only. The production files match the signed archive and the passing local and remote source. TestFlight delivery and hardware acceptance are still pending the owner actions described above.
