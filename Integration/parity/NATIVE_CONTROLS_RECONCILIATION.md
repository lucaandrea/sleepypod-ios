# Native controls reconciliation

October 26, 2026. This controls portion is complete and locally validated; full-app reconciliation and release continue separately. This does not claim physical Pod operation. Preserve Sleepypod's three-tab presentation and shared cards, typography and sheets.

## Source and behavior

- Core `src/hooks/useSchedule.ts` at `88cbee4d0b746da6d5480ff09e8a7e461e87aab7`: the global switch changes only `enabled` on all temperature, power and alarm rows for the selected side, over all seven calendar days. Native presents one explicit side switch (both switches when Both is selected). Enabling also enables individually paused entries; the review explains this. It sends one REST batch, compares the latest rows first, verifies readback and requires reload after an uncertain result. Existing times, temperatures, next-day power offsets and smart-wake/snooze fields survive.
- Graph editing uses Core-style overnight axis domains and 15-minute/whole-Fahrenheit snapping. A point retains its identity; a duplicate time remains a visible validation error. Dragging changes the local draft only. Tapping opens precise editing; VoiceOver can adjust temperature and shift time by 15 minutes. Cancelling discards the draft.
- A controller URL/key/backend change resets the native alarm and curve workspaces. Missing frozen clients remain unavailable. Compact schedule reads and saves ignore old-controller results; saves serialize, and recovery reads do not replay mutations. Compound Core settings/schedule saves freeze their endpoint and cancel unsent writes after an owner revision change.
- Next-alarm dates use the same calendar resolver as the temperature timeline: spring-forward minutes survive, the repeated fall hour is not scheduled twice, and nonexistent calendar midnights are skipped.
- Pump, prime and active-alarm notices now live inside each Temperature layout's scrollable content. Their actions and ownership rows stack at accessibility text sizes. Prime completion rejects future, expired and non-finite timestamps.
- Repeated orbit/reset now keeps a fixed world-up vector in both bed cameras. SceneKit’s convenience `look(at:)` reuses the previous camera up vector; the former reset restored coordinates but left roll behind. A reproduced orientation regression verifies the actual quaternion, not only UI labels.
- The thermal model exposes VoiceOver rotation, zoom and reset actions. Physical pinch, horizontal orbit and the six-second camera return remain local view operations. Base model camera state is also announced accessibly.
- Debug-only independent/disconnected base scenarios supply deterministic simulator evidence without changing ordinary Demo or contacting hardware. A disconnected model does not invent measured positions; Move remains disabled and Stop/Reconnect remain reachable.

## Validation evidence

Results under `build/parity-validation/` are local simulator and contract evidence, not deployed-controller acceptance.

| Result | Evidence |
| --- | --- |
| `Controls-scope-camera-v1` | 53 focused tests: owner changes, frozen clients, prime freshness, camera actions/clamps and existing alarm/curve/temperature/base/thermal regressions passed. |
| `Controls-curve-phone-v3` | Graph projection's three unit cases and the original notices/hold UI flow passed. |
| `Controls-ipad-v1` | Both camera and notices UI flows passed; the first graph test targeted a partially clipped point. Superseded graph test below. |
| `Controls-calendar-ipad-v3` | 20 focused tests and graph drag/cancel UI passed. The helper now brings the full point inside the sheet before dragging. |
| `Controls-complete-phone-v4` | 34 focused tests passed, including global batches, schedule lifecycle, changed-key settings cancellation and DST boundaries. Global pause/resume, notices and camera UI passed. The phone graph gesture failed; v5 verifies the corrected gesture priority. |
| `Controls-gestures-phone-v5` | Twelve base/camera regressions and all six UI flows passed: graph drag/cancel, all-schedule pause/resume, notices with asserted hold values, camera gestures/auto-return/reset, independent-side drafts, and disconnected controls. Nineteen captures are reviewed. |

| `Controls-accessibility-v6` | Five flows passed at maximum text: graph drag/cancel, global pause/resume, Stage camera and both base scenarios. The hold flow hit a menu-dismissal test race; v7 supersedes it. |
| `Controls-accessibility-hold-v7` | All four hold choices and pump/prime/alarm notices passed at maximum text after waiting for each menu dismissal. |
| `Controls-accessibility-layout-v8` | Three flows passed at maximum text after simplifying confirmations and stacking the base heading: global pause/resume plus independent/disconnected base. |

| `Controls-complete-ipad-v9` | All six flows passed on iPad after the final layout changes (19.498s disconnected base, 26.188s independent base, 32.872s graph, 17.252s global switches, 36.115s notices/hold, 20.926s Stage gestures). |

| `Controls-camera-roll-before` | The new actual-orientation regression failed in both bed models (quaternion agreement 0.571/0.580 instead of 1), reproducing the rendering defect. |
| `Controls-camera-phone-v10` | Four camera/prime regressions and both affected camera UI flows passed with the fixed world-up vector. |
| `Controls-camera-ipad-v11` | Both camera flows passed on iPad; corrected reset rendering reviewed. |
| `Controls-camera-accessibility-v12` | Both camera flows passed at maximum text; corrected reset rendering reviewed. |

All 57 retained captures in `previews/controls/{phone,ipad,accessibility}` were visually reviewed. Maximum-text captures include the corrected base heading and concise review dialogs. Strict SwiftLint, `git diff --check`, and the presentation guard pass; the guard confirms the retired shell, components and assets are excluded. Old failed runs remain diagnostic records rather than passing evidence.

## Remaining delivery

Merge the completed controls PR into owner main after its CI checks pass. Complete remaining alarm/layout, curve AI/legacy, personal-comfort direct API, and final combined Health/Shortcuts/privacy/release checks in `PLAN.md`. No build bump or App Store Connect upload until the full parity checklist is reconciled. Hardware movement, pump recovery, alarms and overnight Preview qualification remain separate from synthetic tests.

The first PR #29 device CI build exposed an Xcode 26.6 type-check timeout in the curve handle's long SwiftUI expression. The same modifiers and gesture are now divided between `pointButton` and `pointHandle`. The local unsigned generic-iOS build passes (`controls-device-build.log`); the graph interaction is rerun with the adjacent personal-comfort checks before merge.
