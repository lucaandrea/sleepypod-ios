# Sides and gestures source audit

Status: implemented and locally validated. The existing native BedSidesEditor and iPhone-default-side behavior are retained.

Inspected Core `BedSetupSettings.tsx`, `SideSettingsForm.tsx`, `TapGestureConfig.tsx`, `routers/settings.ts`, and `hardware/gestureActionHandler.ts` on 2026-10-25.

## Sides

- Bed setup: `bedMode` = `two|solo-left|solo-right`; `unusedZoneMode` = `off|follow|independent`. Both use targeted `PATCH /api/settings/device`. Away mode is temporary; bed configuration is persistent; temperature linking remains separate. Both zones retain saved schedules, absent sleepers' alarms pause, and one active sleeper gets one record from bed-wide sensors.
- Side fields come from `GET /api/settings` → `sides.left/right`. `PATCH /api/settings/side` requires `side` and changed fields.
- Name is 1–20 characters under the server's JavaScript string length contract. Away toggle plus optional return date are exposed on web. Preserve the existing `awayStart` value; the router supports it but this web form does not edit it. Return date is an absolute ISO datetime, displayed in the user's local timezone. Reversed start/return ranges are rejected.
- Auto-off: 5–120 minutes. Always-on and auto-off are mutually exclusive and must change atomically in the same patch when enabling either.
- Experimental presence auto-on: 1–60 minutes, HH:mm start/end. Equal window endpoints mean any time. Uses the Pod-local clock, ignores light loads, and follows scheduled/last temperature.
- Presence availability comes from `GET /api/biometrics/occupancy`. The existing native SensorOccupancy decoder exposes each side's `available`. Enabling presence actions requires current availability; disabling must remain possible when presence is missing. Do not infer presence from piezo variance alone.
- Use changed-field preflight conflicts and explicit null for clearing the return date, preserving names/settings on the other side. Local default side is an iPhone preference, not a Pod mutation.

## Gestures

The native TapGestureConfigView is currently read-only. Web has double/triple/quad per side, two action types and removal; it has no base-position gesture action.

- Read records from `GET /api/settings` → `gestures.left/right`.
- Set uses **tRPC only**: `POST /api/trpc/settings.setGesture` with `{json: input}`. It has no OpenAPI route. Decode the normal `{result:{data:{json:...}}}` envelope; server metadata may additionally encode dates.
- Temperature input: side, tapType, actionType=temperature, temperatureChange=increment/decrement, temperatureAmount integer **0–10**. Hardware adds this amount to the selected Fahrenheit target; the UI must not reinterpret it as Celsius or Eight Sleep steps. The controller replaces the firmware's own tap change to avoid doubling it.
- Alarm input: side, tapType, actionType=alarm, alarmBehavior=snooze/dismiss, optional alarmInactiveBehavior=power/none. Optional snooze duration is **seconds, 60–600**; preserve an existing value when editing. The current web editor does not expose duration.
- Delete: `DELETE /api/settings/gesture?side=...&tapType=...`, response `{success:true}`.
- Show both idle behavior and behavior while an alarm rings. Missing mappings are genuinely not set; do not synthesize defaults as saved mappings. Use an unsaved draft only after the user opens an editor.
- A mutation timeout may have committed; require readback before retry. Editing mappings must not actuate the Pod during validation.

## Implementation checkpoint

Native Sides now retains the original BedSidesEditor/default-side diagram and adds bed setup plus separate sleeper pages for away/return, always-on, presence auto-off and experimental auto-on windows. Bed/name/side saves are targeted and preserve other unsaved sections. Changed-field conflicts and uncertain writes require Reload; presence enabling performs a fresh server check. The current route is independent from the older SettingsManager broad-save path, which is tracked in `SETTINGS_APPEARANCE_AUDIT.md`.

The gesture page edits each side's double/triple/quad mapping, shows normal/ringing behavior, writes the exact tRPC discriminated input, preserves existing snooze seconds, and removes mappings through REST. Missing mappings remain Not set. Mutations do not fire the corresponding hardware gesture.

Twenty-one focused logic/transport checks pass in `Settings-menus-accessibility.xcresult`. The two complete settings flows pass at maximum accessibility text, alongside the Device settings regression flow. Presence refresh continues while a sleeper page is pushed, old section-save receipts disappear when a new draft becomes dirty, and selected menu values wrap instead of clipping. Earlier runs exposed a test locator mismatch and the pushed-page presence refresh defect; only the final reruns count as acceptance evidence.

Both primary interaction flows pass in `Sleeper-live-presence-phone.xcresult`, `Sleeper-live-presence-ipad.xcresult`, and `Sleeper-live-presence-accessibility.xcresult`. The final presence fix evaluates freshness at render time, avoiding a brief false-unavailable state when a response arrives after the previous timeline tick. Captures live in `previews/settings-sides-gestures/`. Strict SwiftLint, `git diff --check`, and the compiled presentation guard pass. Tests use explicit simulation and fixture transport; no physical settings or gestures were changed. This does not establish live Pod behavior or release completion. Version remains 0.2.0 (7).
