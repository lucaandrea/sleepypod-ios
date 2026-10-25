# Release evidence — sleepypod 0.2.0 (7)

Date: 2026-10-25. The owner confirmed separate permission to distribute this modified Sleepypod app and authorized the TestFlight release.

## Presentation and features

The host uses Sleepypod’s original Temp, Schedule and Sleep tabs. TempScreen.swift is byte-for-byte identical to upstream revision `2c1ee99ef0b534d9bcdbcf8fdc313cbf0051075e`. Existing schedule and sleep screens retain their original bodies and gain contextual feature menus. The retired Free Sleep shell, feature views, design system and asset catalog are excluded from compilation/resources. Added editors use the original Sleepypod shared components and colors.

Added feature locations, architecture and controller compatibility are documented in README.md. Bed Position has a full-height presentation, an articulated SceneKit preview, orbit controls, mattress toggle, presets, explicit Move and independent Stop. Personal features retain their native services and persisted data. Core’s optional native API is checked against its capabilities before a server-dependent editor opens.

## Verification

- Xcode 27.1; iPhone 18 Pro simulator, iOS 27. The project was opened in Xcode and built/run with Xcode’s xcodebuild and simctl tools.
- **270 unit tests passed:** 35 host XCTest, 162 host Swift Testing, 71 imported Swift Testing and two native compatibility XCTest cases. Five live-Pod XCTest cases skip without POD_TEST_URL. Logs: `/tmp/sleepypod-build7-host-tests.log`, `/tmp/sleepypod-build7-features-isolated.log`.
- **Eight UI tests passed:** five upstream modernization tests and three integration navigation tests. Coverage includes the original three tabs and temperature variants, contextual alarm/journal/report editors, mattress/base controls, routine editor, comfort, model settings, Health history/export, coaching, recorded episodes and Home/Shortcuts. Final integration rerun after the full-height presentation and editor refinements succeeded. Logs: `/tmp/sleepypod-build7-upstream-ui.log`, `/tmp/sleepypod-build7-final-presentation.log`.
- Final screenshots from the actual simulator are in `previews/build7/` and use synthetic demo data. Result bundle: `/tmp/SleepypodUnifiedDerived/Logs/Test/Test-Sleepypod-2026.10.25_13-05-47--0700.xcresult`.
- `verify_presentation.py` confirms original temperature presentation and excluded retired sources/assets. `refresh_features.py ../free-sleep --check` confirms the pinned import and integration overlay reconstruct exactly.
- Production demo isolation was retained. The imported HTTP test fixture uses a process-local UserDefaults argument domain so persisted simulator demo settings cannot redirect HTTP fixture tests.

## Signed release

- Archive: `~/Library/Developer/Xcode/Archives/2026-10-25/Sleepypod-0.2.0-7.xcarchive`.
- App `com.lucaandrea.freesleep` and Watch `com.lucaandrea.freesleep.watchkitapp`: 0.2.0 (7), display name **sleepypod**, minimum iOS/watchOS 26. Existing application identity preserves installations and data.
- App, Watch and embedded framework passed strict code-signature verification. App and SDK privacy manifests declare no tracking. Packaged App Intents and the three license notices were verified in the archive. The asset catalog contains Sleepypod’s original theme assets.
- Export: `build/release-0.2.0-7/Sleepypod.ipa`; SHA-256 `02871ea6c156ab2de3fbafff623199673d523d891be80f95ad4707a6ebec1930`.
- Xcode upload completed at **13:09 PDT**, with `Upload succeeded` and `EXPORT SUCCEEDED` in `/tmp/sleepypod-build7-upload.log`.

## App Store Connect — verified in Safari

- App ID `6822950204`; build [0.2.0 (7)](https://appstoreconnect.apple.com/teams/2cea177f-0ba5-41e1-8e6a-6ea98af67b05/apps/6822950204/testflight/ios/94872024-176c-4480-8318-0087c5192a87).
- Existing **Free Sleep Internal** group is assigned. Its Builds tab shows **0.2.0 (7) — Testing**. The group contains one tester, **ciao@luca.ooo**.
- The build also shows **Individual Tester (1)**, **ciao@luca.ooo**, and confirmation **1 tester has been added**. App Store Connect displays Installed 0.2.0 (7) for that tester.
- WHAT_TO_TEST.txt release notes were saved and verified. Automatic tester notification remains enabled.
- Superseded build 6 was removed from beta review so build 7 could be submitted for the individual tester. Build 7’s beta-review submission is pending; internal testing is available independently.

## Practical limits

Simulator fixtures and code checks do not qualify physical base movement, alarm vibration, overnight comfort, Health/Home permissions, Siri or Watch recording. The coordinated backend chat owns Core migration and the optional native API; unsupported Core features clearly report unavailable. The current UI release preserves existing Free Sleep controller support while that migration continues.
