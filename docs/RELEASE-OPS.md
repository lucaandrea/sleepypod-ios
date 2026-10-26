# Release & App Store operations

This checkout is the owner's modified Sleepypod app. Use the identities and release process below; the upstream publisher's archive script and App Store record do not apply here.

## App Store Connect

- Use **Safari** for App Store Connect and the Apple Developer Portal.
- App record `6822950204` retains bundle ID `com.lucaandrea.freesleep` so the existing app and saved user data remain associated. The display name is sleepypod.
- Team `9FNNQ6J269`, manual Release signing. The iOS profile is `Free Sleep App Store 2026`, with HealthKit and HomeKit entitlements. The companion Watch bundle is `com.lucaandrea.freesleep.watchkitapp`, using `Free Sleep Watch App Store 2026`.
- Export compliance: `ITSAppUsesNonExemptEncryption = false` in `Sleepypod/Info.plist` (HTTPS and local network only). Without it every build sits in "Missing Compliance".
- Privacy: Health access and export are optional. Personal intelligence can use separately configured cloud providers only with the user's consent. Keep privacy declarations consistent with the enabled data paths; app, Watch, framework and SDK manifests are verified in the release archive.

## Archive

- Confirm an unused version/build number in Safari, set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, and run `xcodegen generate`. Commit the generated project with the release metadata on owner `main`.
- Archive the `Sleepypod` scheme in Release for `generic/platform=iOS` with Xcode or `xcodebuild archive`. Run Xcode builds serially. **Do not use `scripts/archive.sh` for this fork:** it derives a version from upstream tags and stamps a different build-number format.
- Use [`Integration/ExportOptions.plist`](../Integration/ExportOptions.plist) for a local App Store export and [`Integration/UploadOptions.plist`](../Integration/UploadOptions.plist) for Xcode upload. Both preserve the selected version/build and explicitly identify the owner's signing profiles.
- Verify app/Watch identity, versions, distribution entitlements, nested signatures, privacy manifests and bundled license notices before upload. A local archive or export does not prove Apple processing or tester access.
- Record owner releases under [`Integration/releases/`](../Integration/releases/). The current signed candidate and its reuse conditions are in [`parity-candidate.md`](../Integration/releases/parity-candidate.md); historical upstream records remain under [`docs/releases/`](releases/README.md).

## TestFlight

- Internal testers (ASC team members) get builds without review, as soon as processing finishes.
- In Safari, verify the processed build is assigned to **Free Sleep Internal** and that **ciao@luca.ooo** has access. Confirm the actual build status and assignments; a successful upload alone is not completion.
- External testers: the first build, and any later build with notable changes, goes through Beta App Review. Test Information must point reviewers at **Explore demo** on first launch — they have no pod.

## Screenshots and previews

- `Marketing/AppStore/capture.py --video` regenerates the App Store screenshots, preview clips and the walkthrough (see its README). Re-run for any release that changes a captured screen.

## Licence and pricing

- Preserve the upstream AGPL-3.0 license, README exception and contributor grant. The upstream publisher's App Store exception does not itself authorize another publisher; the owner has separately confirmed permission to distribute this modified build. Keep the Sleepypod, Free Sleep and SDK license notices bundled.
- If a tip jar or one-time unlock is ever added: free download with an IAP, not a paid download (the hardware and firmware requirement would drive refunds and complicate review). Sign the Paid Apps agreement and complete banking/tax in ASC before the IAP can be reviewed.
