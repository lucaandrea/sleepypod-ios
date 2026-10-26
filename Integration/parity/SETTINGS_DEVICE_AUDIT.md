# Device settings parity audit

Status: native Device parity implemented and locally validated. This does not establish physical operation or completion of the wider release.

Source inspected 2026-10-25: Core `SettingsScreen.tsx`, `DeviceSettingsForm.tsx`, `SensorSourceCard.tsx`, `sensorSourceLogic.ts`, `routers/settings.ts`, `routers/system.ts`, and `routers/health.ts`.

## Scope and contracts

- `GET /api/settings` returns the complete device row. `PATCH /api/settings/device` accepts changed fields only. Read back through GET after a mutation because the PATCH output schema omits `globalMaxOnHours`.
- Device controls: IANA timezone, Fahrenheit/Celsius, 12/24-hour clocks, default schedule end action, optional 1–48 hour power cap, daily reboot/prime with independent times, daytime LED brightness, LED night mode/time window/brightness.
- Pump protection's six supported fields already have a native editor and validation. Link it here rather than duplicate its draft/state.
- `GET /api/system/sensor-source` is read-only. It reports the firmware generation, automatic RAW/NATS choice, overrides, last-frame age/type and service uptime. Pending selection, first-frame grace (90 seconds), stale frames (>60 seconds), and expected-transport mismatch must be distinguished.
- The web button labelled “Restart service” currently calls `system.triggerUpdate`, which starts `sp-update main`, including download/install/build. This is not a restart-only contract. Reported to the owning Core chat. `/api/health/restart-service` currently allows three biometrics services only, not the main controller. The owning Core chat has corrected the contract: `POST /api/health/restart-service` with `{unit:"sleepypod.service"}` returns `{ok,message}` and queues a non-blocking restart. Native consumes this exact route, requires product confirmation, separates denied/requested/unconfirmed outcomes, clears old source observations, and requires reconnect after acknowledgment or a lost response. It never calls the updater from Restart. The restart-only change merged through owner Core PR #24 at `6452f3f94b31b3e9ad6d54ad94f827a4fc181c62`; a separate restricted-maintenance follow-up is in progress.
- Reconnect means refresh native connection/status/settings, not a controller mutation.

## Native gaps found

The existing DeviceSettingsCardView has an inert timezone row and LED slider, an incorrect claim that priming always runs one hour after reboot, and no LED night schedule or power cap. SettingsManager's compatibility save writes multiple unrelated fields and both sides. The new screen must use bounded targeted patches, preserve drafts, and require readback after an uncertain save.

Native DisplayTime currently hard-codes 12-hour formatting. Apply the reported Core clock preference to shared schedule/curve labels without changing stored HH:mm times or schedule timezone.

Bed setup, side profiles/away ranges/presence controls and gestures are separate following slices. The current web gesture editor supports temperature and alarm/power behavior only; it has no base-angle gesture action.

## Implementation and validation checkpoint

The native Device screen is implemented with changed-field patches, explicit null to disable the cap, independent maintenance clocks, LED schedules, searchable IANA zones, 12/24-hour shared labels and clock pickers, and ten-second read-only source refresh. Source selection/first-frame grace/stall/freshness are explicit. Pump protection reuses its existing editor.

Fifteen focused unit/transport checks pass in `Device-final-phone.xcresult`: changed-field/null patches, validation, same-field conflicts, unrelated changes, unknown writes/readback, source freshness and restart outcomes. The final restart review uses a scrollable sheet after visual review caught a cramped system popover at maximum text size.

`Device-review-phone.xcresult`, `Device-review-ipad.xcresult` and `Device-review-accessibility.xcresult` pass the complete edit/save/source/restart/reconnect flow. Reviewed captures in `previews/settings-device/` cover iPhone dark, iPad light, and maximum accessibility text. Clock pickers retain 24-hour display and source content stays left aligned. Strict SwiftLint and the presentation guard pass.

The route requires the coordinated Core restart-only implementation (Core PR #24). An older server may reject it; native shows failure and never falls back to the updater. No physical service restart or setting mutation has been performed. Version remains 0.2.0 (7).

Device PR #14 merged into owner main at `8c51d6d657e8d216c55f76b228177175844ebf60` after all four CI checks passed (run `40269987801`). A subsequent maximum-text menu-label correction is verified by the complete Device flow in `Settings-menus-accessibility.xcresult`; its nine refreshed captures replace the earlier accessibility images.
