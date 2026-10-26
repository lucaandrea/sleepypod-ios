# Appearance source audit

2026-10-25. In progress; do not mark parity complete yet.

Core `AppearanceSettings.tsx` exposes Dial/Slider/Now–Night–Dawn; Degrees/Offset/Eight Sleep; six-zone visibility and camera auto-return; theme; and Pod-wide Fahrenheit/Celsius. Native `AppearanceSettingsScreen` already maps each control to `UserProfile`, with native-only Both sides and Cards/Stage choices retained. `TemperatureStageScreen` consumes zone and camera preferences. Device settings now owns the 12/24-hour clock preference.

Remaining checks:

- Exercise every appearance picker/toggle, preference persistence, and final maximum-text/iPad layout. Existing TemperatureParityUITests cover Stage and scales, not the complete settings workflow.
- Correct the older `SettingsManager.updateTemperatureFormat` / `SleepypodCoreClient.updateSettings` save path: a unit-only change currently rewrites timezone, maintenance and both side names/away flags from the cached settings. Quick Away and legacy rename methods share it. Add an original-snapshot/changed-field save contract so new Device/Side settings cannot be overwritten by an unrelated older control; verify conflicts, readback and failure reporting. Keep legacy Free Sleep compatibility through the protocol default. This is separate from the new targeted Device/Sides clients.
- Keep sensor values in actual degrees when the comfort display uses Offset/Eight Sleep. Existing tested conversion contracts remain authoritative.

Source reconciliation found that native `ThermalBedSceneView.Coordinator.scheduleReturn` currently waits six seconds and does not gate on selection; web waits eight seconds with no selection. Native Stage also uses the global control side as scene selection, so it lacks a separate unselected stage state. Resolve this in the remaining Temperature/Stage interaction audit before claiming parity. The settings help must not promise the web behavior until it is implemented.
