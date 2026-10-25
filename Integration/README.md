# Sleepypod iOS with personal features

The application uses Sleepypod's original **Temp · Schedule · Sleep** navigation, temperature dial, schedule curve, sleep charts, onboarding and settings design. The legacy Free Sleep app shell, UI components, colors and 3D bed renderer are excluded from compilation and resources. The app's display name is `sleepypod`; its existing `com.lucaandrea.freesleep` identity preserves saved connections and user data.

## Presentation and maintenance

- Upstream Sleepypod: https://github.com/sleepypod/ios at `2c1ee99ef0b534d9bcdbcf8fdc313cbf0051075e`. Build 7 retained its temperature screen exactly; subsequent owner-requested web parity adds Stage, temperature scales and control ownership alongside the original Cards layouts.
- `SleepypodUI/` contains Sleepypod's shared theme and components, compiled into both modules. Fonts and color assets come only from Sleepypod. Segmented controls stack at accessibility text sizes to keep their labels readable.
- `SleepypodFeatures/` contains detail editors ported to those components. They own no tab bar, app shell or independent navigation stack (except modal editors). `PodFeatureScreen` is their public entry point.
- `FreeSleepKit/` preserves the pinned feature source and its domain/service code. `App/RootView.swift`, `App/FreeSleepApp.swift`, `Design/`, `Features/` and `Resources/` are excluded from the framework target. The legacy asset catalog is not bundled.
- `Integration/UnifiedWorkspace.swift` now contains runtime integration and App Intents registration only.
- `FreeSleepKit.patch` records changes to the pinned import. Verify reconstruction with `python3 Integration/refresh_features.py ../free-sleep --check`. Updating the imported source does not replace the independent Sleepypod presentation.
- The original Sleepypod license, Free Sleep source license and AIProxy notice are bundled. The owner confirmed separate permission to distribute this modified Sleepypod application on 2026-10-25.

## Feature locations

| Feature | Location |
| --- | --- |
| Temperature, power, linked sides, Stage and display scales | Temp screen and Appearance settings |
| Schedules, wake alarms, curve library and run-once | Schedule screen and options |
| Full-week drafts, copy days, conflict checks | Schedule options → Routine editor |
| Change/skip/restore one alarm | Schedule options → Next alarm |
| Sleep records, Night/Week/Month summaries, Watch comparisons | Sleep screen |
| Biometrics, sessions, chart navigation, raw data and reference import | Sleep options → Biometrics / Raw data |
| Pod stage rules, previews, history and model library | Settings → Pod sleep stages |
| Journal, personal reports, coach, episode editing | Sleep options menu |
| Head/feet, presets, rotating model, mattress toggle, Stop | Settings → Bed position |
| Bounded personal comfort and activity | Settings → Personal comfort |
| Health history, export, model keys and limits | All settings → Health / Insights |
| Home bridge, existing Home scenes, Shortcuts | All settings → Connections |
| Pod preferences and service diagnostics | All settings → Pod |

The existing routines, alarm actions, journal drafts, record edits, Health engine, provider clients, consent checks, usage limits, Home scene execution and App Intents remain backed by the imported domain/services. New detail screens use Sleepypod grouped settings, native toggles and sliders, and its capsule buttons.

## Controller compatibility

Sleepypod Core uses authenticated `/api/trpc` and `/api` endpoints. Imported personal features use the existing Pod API or an explicitly advertised `/api/native/v1` contract. On Core, server-dependent detail editors first check `/api/v1/capabilities`; absent, unready or unknown compatibility contracts show unavailable without mounting the editor. Local Health history and model setup remain accessible independently.

Controller migration remains owned by the coordinated backend chat. This iOS update does not migrate a Pod. Origin-scoped Keychain keys, rejected redirects, HTTPS requirements and same-host WebSocket validation are retained. Demo mode issues no live commands.

Both existing Health workflows remain opt-in. Choose one export workflow per record source to avoid duplicate samples. Hardware movement, alarm vibration, Health/Home authorization and Siri still require attended checks; simulator screenshots use synthetic data.

## Build and release

Use Xcode 27.1 and `xcodegen generate`. The release keeps iOS/watchOS 26 minimums and the existing Apple Distribution profiles. Archive with Xcode, export/upload using the checked-in options plists, and use **Safari** for App Store Connect changes. The owner explicitly authorized build 7 distribution and assignment to the internal group and `ciao@luca.ooo`.

`VALIDATION.md` and `previews/build7/` record the historical build 7 release. The subsequent parity work is **in progress**, with its remaining requirements and current evidence in `parity/PLAN.md`. Merging tested changes into the owner's `main` does not signify a new TestFlight release; the release version remains 0.2.0 (7) until the complete parity audit is finished.
