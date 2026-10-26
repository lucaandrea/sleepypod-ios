# Native room sensors and Home Assistant setup

2026-10-26. Source contract: Core PR #29, `cbb0e5bd45c723888e44e8506ef91fdf9b380630`, `docs/ROOM_CONTEXT.md`, the room router, schema/store, Home Assistant publisher generator and web RoomContext panel. The app keeps Sleepypod cards, settings navigation and its original three-tab shell.

Room sensors appears under Settings, mapped measurements under Temperature, and a compact card under Home & Shortcuts. These are separate from the Pod ambient measurements. Five supported metrics retain source units in configuration and normalized units in observations. Display temperature follows the user's degree unit independently of the dial's Offset/Eight Sleep setting.

A measurement is shown only when the current mapping is enabled, MQTT is connected, Core labels it fresh, its source timestamps are ordered, its source expiry has not elapsed and the app has a successful foreground read within fifteen seconds. Backgrounding, failed reads, reversed local time and expiry withhold live values; historical values never fill a live gap. Owner/controller changes replace the workspace and invalidate prepared saves.

Mapping edits retain their original revision and draft. Review freezes the full configuration and workspace identity. Saving uses Core's expectedRevision compare-and-swap. Conflicts preserve the draft. A lost response withdraws readings and permits readback only; no automatic write replay occurs. A matching newer revision confirms the request, while an unchanged revision preserves the draft for a new explicit review. This recovery is in memory; reopening starts with a remote read and never resends.

Home Assistant publisher documents come from the controller for the fresh saved revision. Every mapping save withdraws previous documents. Copy and Share expose only those generated documents; the app does not ask for Home Assistant credentials, publish MQTT input, enable an automation or control accessories. The mapping form identifies the measured-at source attribute and supported timestamp format instead of inventing a timestamp.

History loads explicit 200-item cursor pages, capped at 25,000 loaded rows. The JSON export identifies its scope as loaded historical pages only. Normal Demo remains empty/unavailable; the UI test's DEBUG-only synthetic fixture is explicitly labelled, has in-memory saves and cannot send household measurements. The fixture generator imports the immutable Core contract and publisher generator without starting a database or server.

## Validation

Eleven focused model/workspace/REST checks pass in `Room-accessibility.xcresult`: literal Core publisher shape; unit, age, name and duplicate mapping bounds; server-time expiry and failed-read withholding; lost-save readback without replay; conflict preservation; owner-bound reviews; publisher revision invalidation; paged history/export and all four exact REST operations. The normal Demo mapping flow also passes. The full synthetic reading → publisher → history → reviewed save → withdrawn reading flow passes on phone (`Room-phone-v4.xcresult`, 47.067 seconds), iPad light (`Room-ipad.xcresult`) and maximum text (`Room-accessibility.xcresult`, 140.186 seconds). The normal empty Demo mapping flow also passes on all three. Twenty-five captures are retained in `previews/room-context/` and reviewed.

The initial synthetic flow exposed duplicate inherited accessibility identifiers in the room summary and expanded publisher. The screen now has a scope identifier and publisher Copy/Share actions have distinct identifiers. Mapping bindings find entries by metric so a refreshed configuration cannot leave an array-index binding pointing outside the draft.

No live MQTT measurements, physical room sensor setup, controller mapping mutation, app version change or release is part of these local checks.

The save regression verifies that withdrawing the pre-save status does not briefly announce a conflict. Maximum-text captures include this correction; the earlier phone/iPad saved-mapping capture records the superseded transient message. A subsequent layout check replaces the clipped timestamp-format Picker with a labelled wrapping menu. `Room-format-accessibility.xcresult` passes (69.112 seconds), and its final format/normal-Demo captures supersede those earlier maximum-text images. Mapping entries use metric-based bindings across refresh. Strict SwiftLint, diff checks and the built-product presentation guard pass.
