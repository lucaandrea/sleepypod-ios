# Release evidence — Free Sleep 0.2.0 (6)

Date: 2026-10-25. Distribution permission for the modified SleepyPod app was explicitly confirmed by the owner in this task.

## Built and exercised

- Xcode 27.1; iPhone 18 Pro simulator, iOS 27. The project was opened in Xcode and built/run using its `xcodebuild` and `simctl` tools.
- Build 5 completed 268 unit tests successfully: 35 XCTest cases, 162 SleepyPod Swift Testing cases, and 71 FreeSleepKit cases. Five additional XCTest cases were skipped. Coverage includes SleepyPod's existing tests and the imported Free Sleep suites. Five read-only live-Pod tests skip when `POD_TEST_URL` is absent; no live-device results are implied by these tests.
- New connection tests verify origin-scoped bearer headers, authenticated same-host WebSocket configuration, refusal of remote plaintext setup, base readiness without reported position, and returning from demo to the original controller.
- Core REST and WebSocket regression tests preserve powered state at neutral temperature. Concurrent native clients retain their own API prefix and credentials, and a missing Core compatibility route reports unavailable without retrying commands.
- Build 5 UI smoke test completed with `TEST SUCCEEDED` (`/tmp/sleepypod-build5-ui-tests.log`): Tonight → bed preview, Sleep, Autopilot, Home and More. Demo Stop was disabled. Simulator screenshots are in `previews/` and use synthetic data.
- Pinned FreeSleepKit source plus the recorded integration patch reconstructs exactly (`refresh_features.py --check`).

## Distribution

- Signed archive: `~/Library/Developer/Xcode/Archives/2026-10-25/FreeSleep-0.2.0-6.xcarchive`.
- App: `com.lucaandrea.freesleep`, version 0.2.0, build 6, minimum iOS 26.
- Watch companion: `com.lucaandrea.freesleep.watchkitapp`, same version/build, minimum watchOS 26. Its missing upstream app-icon asset was added after Apple's first validation attempt identified it.
- Both bundles and the embedded framework passed strict signature verification. App and SDK privacy manifests declare no tracking and the optional Health/user-content processing used by the app. Packaged App Intents include the FreeSleepKit package through Apple's `AppIntentsPackage` mechanism.
- Apple accepted build 5 at 12:27 PDT on 2026-10-25: `/tmp/sleepypod-build5-upload.log` ended with `Upload succeeded` and `EXPORT SUCCEEDED`. It supersedes build 4 with a per-connection native API prefix fix.
- Final build 6 adds bundled SleepyPod, Free Sleep and AIProxy license notices; application code is unchanged from the tested build 5. The archive completed successfully and strict signature verification passed. Both app/Watch versions, icons, privacy declarations, packaged intents and all three bundled notices were verified against their source files before upload.
- Signed IPA export: `build/release-0.2.0-6/Sleepypod.ipa`; the versioned archive above is retained in Xcode Organizer. IPA SHA-256: `ee4388b86a13860de27284f1856093c09cddacc200ebe3d72957b294b658afeb`.
- Existing App Store Connect app ID: `6822950204`. Internal group `Free Sleep Internal` contains `ciao@luca.ooo`; Safari verified build 6 assigned to that group with status **Testing**.
- Safari confirmed **Individual Tester (1)** with `ciao@luca.ooo` and the success message **1 tester has been added** on build 6. The tester status displayed Installed 0.2.0 (6). Release notes match `WHAT_TO_TEST.txt`, and automatic tester notifications remain enabled.
- The older build 4 beta-review submission was withdrawn to allow final build 6 to be submitted; builds 4 and 5 are superseded.
- Final build details: https://appstoreconnect.apple.com/teams/2cea177f-0ba5-41e1-8e6a-6ea98af67b05/apps/6822950204/testflight/ios/06348352-9ee3-4ec1-bc29-555883f1de75.
- Apple accepted final build 6 at 12:33 PDT on 2026-10-25; `/tmp/sleepypod-build6-upload.log` ended with `Upload succeeded` and `EXPORT SUCCEEDED`. Safari confirmed processing complete and final tester assignments saved. Internal group status is **Testing**; the individual-tester beta-review submission is pending.

## Practical limits

The actual Pod remains on Free Sleep. The other chat owns Core deployment, private HTTPS access and the native compatibility handlers, and is continuing the comfort runtime implementation. `/api/native/v1/` is agreed but not implemented by the coordinated Core revision. Native features remain present in the client and show unavailable when their server service is missing. This release does not qualify physical base motion, alarm vibration, overnight comfort, Health/Home permissions, Siri, Watch motion or remote-network access.

The final host and imported-feature test runs each completed with `TEST SUCCEEDED`; their logs are `/tmp/sleepypod-build5-host-tests.log` and `/tmp/sleepypod-build5-features-tests.log`. The earlier combined run exposed mutable global API routing and stalled during result finalization; the corrected build uses an immutable per-connection prefix. `.xcresult` bundles live under `/tmp/SleepypodUnifiedDerived/Logs/Test` for this session. Fixtures use synthetic data and credentials.
