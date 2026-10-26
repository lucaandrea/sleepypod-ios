# Final native parity reconciliation

26 October 2026. Software implementation checkpoint, not a TestFlight or physical-hardware completion claim. Version remains 0.2.0 (7) until integration/release checks finish.

## Audited scope

The public demo walkthrough in `DEMO_NOTES.md` covers Temperature, Base, Schedule, Sleep, all ten System tabs and the eleven Settings sections. Its source baseline is upstream development `47034d44b9dd113890ca05e3ba6af38a29978e1d`; coordinated personal contracts are recorded in the feature audits, through optional temperature application history at Core `5c7601d` and owner qualification/activation at Core `41d6f93`. Core PR #45 (`c105621`) subsequently adds deployment preparation and recovery tooling without changing these native API contracts. Each substantive workflow has a native screen or existing native equivalent, typed transport/model coverage and source-specific loading, empty, error and stale behavior. The detailed audits in this directory are the evidence map. Older audit notes listing later work are resolved by `NATIVE_CONTROLS_RECONCILIATION.md`, `ALARM_CURVE_RECOVERY_AUDIT.md`, the personal integration audits and this checkpoint.

The original Temp / Schedule / Sleep shell, Cards controls, grouped settings, fonts and assets remain. The compiled presentation guard rejects the retired Free Sleep shell, components and asset catalog. Imported domain/services and App Intents are preserved by a reproducible, pinned source overlay; `refresh_features.py ../free-sleep --check` passes after refreshing that overlay.

## Last Stage difference

The web returns the camera after eight idle seconds with no selected side. Native Stage now keeps scene selection separate from the control side, clears it on a second side tap, empty-space tap or Reset, and displays selection-only zones only while selected. Deselecting never changes a target. Selection cancels an outstanding return, clearing selection starts a new delay, and disabling the preference cancels return. Reduced Motion disables animated camera returns. Native vertical scrolling, two-finger tilt, orbit, pinch, VoiceOver actions and reset remain intact.

The deterministic selection/cancellation regression passes, as do actual Stage selection, pinch, timed return, orbit and reset flows on phone, iPad and maximum text. Nine final Stage captures were reviewed. The former six-second behavior recorded in early audits is superseded.

## Combined validation

`Parity-final-regression-v1.xcresult`: **925 passed, 5 skipped, 0 failed, 930 total**. This combines all Sleepypod and imported-feature unit/transport tests with the phone Stage interaction. The five skipped tests explicitly require a live Pod. Health consent/export/cleanup, Shortcuts, owner changes, schedule contracts, journal/report integrity and all existing native feature regressions are included. Focused history and Stage runs cover iPad and maximum Dynamic Type. Strict lint, `git diff --check`, source reconstruction and the compiled presentation guard pass.

After owner qualification was added, all **936 unit/transport tests passed**, with the same five live-Pod skips. This is the completed unit/transport portion of `ComfortOwner-AX-final-v7`; its subsequent replay-chart UI test passed, then the owner walkthrough was intentionally interrupted for the expandable-night-list refinement. That overall result bundle therefore records a cancellation and is not claimed as a complete passing run. The final owner UI runs (`ComfortOwner-AX-v8`, `ComfortOwner-phone-v9` and `ComfortOwner-ipad-v10`) pass. Together with the unchanged attended-check flows in phone v4 and iPad v6, they cover both owner walkthroughs on all three presentations. All 27 owner captures were reviewed.

Remote Xcode 26.3 revealed type-checker timeouts absent from Xcode 27.1. Explicit journal sums/means, separate presence-chart sizing/rendering helpers and extracted temperature-dial labels/geometry preserve behavior while reducing compiler complexity. The Intel runner also exposed ambiguous mixed CGFloat/Double arithmetic in the stage timeline and dial; view coordinates now use explicit CGFloat values. Explicit sensor paired-mean intermediates and typed replay-chart marks resolve two further compiler timeouts without changing their calculations or rendering. Eleven temperature regressions and an actual dial drag followed by an Eight Sleep step pass after the dial refactor (`Dial-compiler-v1.xcresult`); eleven sensor-calibration checks and the maximum-text replay interaction also pass. The integrated GitHub device build passes. Its test compile then exposed one overloaded biometric fixture expression; explicit record/offset types preserve its six samples and all assertions. All six `BiometricAxisTests` pass locally after this test-only correction (`BiometricAxis-compiler-v1`). The final integrated GitHub run remains the merge gate.

## Owner qualification and activation

The final coordinated Core addition has a native workflow under Personal comfort. It reads actual activation authority separately from saved mode, shows all six attended checks and seven matching reviewed nights, prepares a bounded review, and requires explicit owner consent before confirmation. Expiry includes preparation latency. Unknown outcomes require readback and cannot replay commands. Recovery and retest preserve the recorded evidence; synthetic examples cannot confirm or activate. `OWNER_ACTIVATION_AUDIT.md` records the production-generated fixtures, logic/transport checks and rendered interaction evidence.

## Privacy, signing and distribution

- Owner keys and model keys remain in Keychain; model keys use WhenUnlockedThisDeviceOnly. Reports remain file-protected, and per-request sharing consent resets with evidence/provider/question changes. Demo cannot dispatch a model request.
- Core foreground/background/Shortcut Health export shares one writer and selective consent. Bed presence, sleep analysis, Watch references and source-qualified SDNN remain distinct. App HealthKit/HomeKit and motion/microphone purpose descriptions match the implemented workflows.
- Privacy manifests now exist in the app, imported framework and Watch bundle. Own preferences use CA92.1; selected-file metadata uses 3B52.1; audio event absolute timestamps use 8FFB.1. Bundle presence and plist syntax were verified. These declarations follow [Apple's approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons?language=objc) and [per-bundle manifest requirements](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api). No tracking is declared or introduced.
- Sleepypod, Free Sleep and AIProxy licenses remain bundled. The owner confirmed separate distribution permission on October 25. Existing app identity/team are retained; release signature/profile validation still belongs to the final archive.

## Remaining external acceptance

The ESP is physically installed, on the owner's Wi-Fi and out of sample Preview. Current serial diagnostics still show no configured Core controller. The coordinated backend chat owns the attended cutover; a verified LAN endpoint and protected credential handoff are required before ESP live status can be checked. Firmware touch/layout acceptance was supplied by the owner; Wi-Fi alone does not establish live bed control.

Safari access was blocked by the locked Mac during this checkpoint; the owner has been asked to unlock it. Final archive/upload, App Store Connect processing and assignment of the internal group and ciao@luca.ooo remain pending. No physical Health write, Home pairing, Siri invocation, actuator movement, alarm delivery or overnight comfort qualification is claimed from synthetic tests.
