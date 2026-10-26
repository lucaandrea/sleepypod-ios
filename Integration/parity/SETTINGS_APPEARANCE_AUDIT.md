# Appearance settings parity

2026-10-25. Appearance screen and shared settings-save implementation and responsive verification are complete. Temperature Stage interaction parity remains separately tracked.

## Source reconciliation and behavior

Core `AppearanceSettings.tsx` exposes Dial/Slider/Now–Night–Dawn, Degrees/Offset/Eight Sleep, zone visibility, camera auto-return, theme and Pod-wide Fahrenheit/Celsius. Native Appearance retains Sleepypod grouped cards and adds no retired Free Sleep UI. Native-only Both sides and Cards/Stage preferences remain available. Device settings owns the independent 12/24-hour clock preference.

All local display choices retain UserProfile storage. Sensor readings stay in actual degrees independently of the comfort scale. The original normal menu-row composition remains, with wrapping values and a stacked camera toggle at accessibility sizes. Explicit menu actions support server-confirmed values; VoiceOver receives the selected value. Light/Dark changes now also update the open Settings presentation immediately, rather than waiting for dismissal.

The compatibility SettingsManager save path carries the original snapshot. Core freezes the controller endpoint, rereads current settings, compares edited fields and PATCHes only those fields. A unit change cannot rewrite maintenance, side names or Away flags. A successful PATCH followed by a mismatched readback remains unresolved until reload. Multi-field legacy actions retain partial/unknown-outcome errors and require readback before another save. This is changed-field preflight, not atomic compare-and-swap. The older Free Sleep backend keeps its protocol fallback.

SettingsManager no longer presents unconfirmed optimistic values or clears a write failure with an automatic fetch. It serializes saves, rejects late reads/saves after backend changes, keeps the new backend's busy state independent, and uses reported Pod units ahead of the offline display fallback. Appearance, quick Away, All Settings units and the legacy side editor expose saving/error/reload feedback.

## Validation checkpoint

Thirteen focused checks passed in `Appearance-final-phone.xcresult`: five change/preference tests, five literal transport tests, and three deterministic lifecycle tests. The earlier `Appearance-phone.xcresult` also passed 17 startup regressions with five explicit live-Pod tests skipped, plus the existing Appearance UI regression. No physical settings were changed.

The complete preference/relaunch flow passed on iPhone in `Appearance-awaited-phone.xcresult` (161.744 s), iPad in `Appearance-actions-ipad.xcresult` (132.987 s), and maximum accessibility text in `Appearance-actions-accessibility.xcresult` (190.553 s). The flow checks every preference and actual rendered-background colors for Light/Dark. Twelve captures are retained under `previews/settings-appearance/{phone,ipad,accessibility}` and were visually inspected.

Visual inspection found and corrected the original stale cover theme. iPad inspection found a native Picker could retain its old unit during an asynchronous save; explicit selection actions correct that. Menu option identifiers distinguish choices from same-named controls behind the cover. The final iPhone test waits for the confirmed asynchronous value before continuing; an earlier immediate assertion failed while the units menu remained open. The same explicit action menu is used in All Settings. Its repeated Celsius/Fahrenheit flow passes on iPhone, iPad and maximum text in `Appearance-final-{phone,ipad,accessibility}.xcresult`. Strict SwiftLint, the presentation guard and `git diff --check` also pass. No live Pod writes were sent.

## Remaining Stage work

Source reconciliation found that native `ThermalBedSceneView.Coordinator.scheduleReturn` waits six seconds and does not gate on selection; web waits eight seconds with nothing selected. Native Stage uses the global control side as scene selection, so it lacks an independent unselected scene state. Resolve camera timing, reduced-motion handling, scene selection and zone rendering in the remaining Temperature/Stage audit. Settings help intentionally describes the preference without promising an unimplemented timing rule.
