# Native parity release candidate

26 October 2026. **Signed local archive and IPA export; not uploaded or assigned in TestFlight.**

## Source and validation

- Implementation: `193cf9d1733db76c92a9695197a31f8ea332049a`, passing all four jobs in [CI run 40351229111](https://github.com/lucaandrea/sleepypod-ios/actions/runs/40351229111).
- Main integration: `ecde9906b8e4425b34abb230b56dc47942bfe418`, with an identical tested tree. All PRs #34–39 are merged and their six feature branches are removed.
- Final local iOS 27 and remote iOS 26 unit/transport runs each pass 936 tests, with five explicit live-Pod skips and no failures. The native phone/iPad/maximum-text evidence is in `../parity/FINAL_RECONCILIATION.md`.

## Candidate artifacts

Provisional version **0.3.0 (8)** was supplied as explicit Xcode archive settings after parity validation. App Store Connect has not yet confirmed that the build number is unused. The checked-in project remains 0.2.0 (7) until that check and the release metadata update.

- Xcode Organizer archive: `~/Library/Developer/Xcode/Archives/2026-10-26/Sleepypod-0.3.0-8-candidate.xcarchive`.
- IPA: `build/parity-validation/Export-0.3.0-8-candidate/Sleepypod.ipa`.
- IPA size: 30,006,048 bytes.
- IPA SHA-256: `39c7f2ac2c05e87a54ebe497c153b7c95ee53156b4d9707126ece58a1cc1dd76`.
- Build/verification records: `Archive-candidate-0.3.0-8.log`, `Export-candidate-0.3.0-8.log` and `release-candidate-verification.json` under `build/parity-validation/`.

Xcode archive and local App Store export succeeded. The archive and extracted IPA pass strict signature verification, including their nested Watch/framework code. App/Watch versions and identifiers match. Both distribution profiles expire on 14 October 2027; development debugging is disabled. The app has its HealthKit/HomeKit entitlements. App, Watch, framework and SDK privacy manifests are present and declare no tracking, and all three license notices and App Intents metadata are bundled. Compiled release source lists exclude the retired Free Sleep presentation and include Sleepypod's shared components.

## Remaining delivery

Safari remains inaccessible while the Mac is locked. Once available, verify the next unused build in App Store Connect, update `project.yml` and regenerate the project, then upload through Xcode and verify processing and the requested internal group/tester assignment in Safari. Reuse this candidate only if its version remains available and compiled source/resources/settings remain equivalent; otherwise archive again. Feature-oriented internal test notes are prepared in `parity-test-notes.md`.

The ESP is on Wi-Fi and out of sample Preview. It still needs the final live Core endpoint/key after the coordinated attended controller cutover. That cutover awaits the existing owner attendance confirmation. This candidate is not evidence of live bed control, Health writes, Home pairing, Siri invocation or overnight comfort qualification.
