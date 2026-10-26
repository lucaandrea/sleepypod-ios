# Native parity release candidate

26 October 2026. **Delivered to internal TestFlight.** Safari verified Apple validation, the internal group's Testing status and the individual tester assignment. See [build8.md](build8.md) for the final delivery record and the separate beta-review state.

## Source and validation

- Implementation: `193cf9d1733db76c92a9695197a31f8ea332049a`, passing all four jobs in [CI run 40351229111](https://github.com/lucaandrea/sleepypod-ios/actions/runs/40351229111).
- Main integration: `ecde9906b8e4425b34abb230b56dc47942bfe418`, with an identical tested tree. All PRs #34–39 are merged and their six feature branches are removed.
- Final local iOS 27 and remote iOS 26 unit/transport runs each pass 936 tests, with five explicit live-Pod skips and no failures. The native phone/iPad/maximum-text evidence is in `../parity/FINAL_RECONCILIATION.md`.

## Candidate artifacts

Version **0.3.0 (8)** was supplied as explicit Xcode archive settings after parity validation. Safari confirmed that build 7 was the latest prior upload. Commit `4264be98ee2a074a7108e0bdc94905924a89fcb6` updates the checked-in project to 0.3.0 (8); XcodeGen changed only those version fields. The generated project exactly matches the archived settings after applying the same version overrides, so the verified candidate was reused without source or resource changes.

- Xcode Organizer archive: `~/Library/Developer/Xcode/Archives/2026-10-26/Sleepypod-0.3.0-8-candidate.xcarchive`.
- IPA: `build/parity-validation/Export-0.3.0-8-candidate/Sleepypod.ipa`.
- IPA size: 30,006,048 bytes.
- IPA SHA-256: `39c7f2ac2c05e87a54ebe497c153b7c95ee53156b4d9707126ece58a1cc1dd76`.
- Build/verification records: `Archive-candidate-0.3.0-8.log`, `Export-candidate-0.3.0-8.log` and `release-candidate-verification.json` under `build/parity-validation/`.

Xcode archive and local App Store export succeeded. The archive and extracted IPA pass strict signature verification, including their nested Watch/framework code. App/Watch versions and identifiers match. Both distribution profiles expire on 14 October 2027; development debugging is disabled. The app has its HealthKit/HomeKit entitlements. App, Watch, framework and SDK privacy manifests are present and declare no tracking, and all three license notices and App Intents metadata are bundled. Compiled release source lists exclude the retired Free Sleep presentation and include Sleepypod's shared components.

## Upload and remaining acceptance

Xcode Organizer uploaded the archive at **10:14 AM America/Los_Angeles on 26 October 2026**. Its persisted upload receipt reports success, no errors and no warnings for app `6822950204`, build 8. Version management was disabled, symbols were included, and the existing owner app/Watch profiles were selected. An earlier command-line upload failed account access before transfer; the signed-in Organizer completed the upload. Safari subsequently displayed **Processing** for 0.3.0 (8). Local receipt and project-equivalence evidence are under `build/parity-validation/`.

Safari subsequently confirmed the processed binary as **Validated**. Build 0.3.0 (8) is **Testing** in **Free Sleep Internal**, and **ciao@luca.ooo** is present both in that group and as an individual tester. The separate individual-tester beta review was submitted; internal access is active. Feature-oriented internal test notes are saved. Final evidence: [build8.md](build8.md).

The ESP's last USB check confirmed Wi-Fi and sample Preview off. It still needs the final live Core endpoint/key after the coordinated attended controller cutover. It is currently disconnected from USB; the owner will reconnect it later. The cutover remains with the backend chat and requires its attended handoff. This release is not evidence of live bed control, Health writes, Home pairing, Siri invocation or overnight comfort qualification.
