# Remote sleep stages and model library — in progress

2026-10-25. Native Sleepypod cards, navigation and three-tab shell are retained. No real controller classification was changed during validation.

## Source contract

- Compared the public web demo's Sleep stages settings and Core dev `47034d44b9dd113890ca05e3ba6af38a29978e1d`: `src/components/Settings/{SleepStageRules,PersonalModelCard,ModelScorecard}.tsx`, `src/server/routers/sleepStages.ts`, `src/lib/personal-stage-model.ts` and `src/server/routers/biometrics.ts`.
- The coordinated Core fork's rule editor follows desired versus acknowledged classifier generations. Saved pending rules do not relabel the displayed historical view before processor adoption.
- Model-library routes are detected from OpenAPI. The coordinated Core `personal-stage-models` working branch now supplies the six library/selection/activation/preview routes; their method and response shapes were compared with this client. Its final merged revision and integration evidence are still pending. Controllers without these routes retain the independent iPhone model tools and show the missing remote capability explicitly.

## Implemented

- Native per-side ordered compound rules, first-match semantics, presets, quick thresholds, fallback, signal limits, low-signal rules, smoothing and transition CRUD. Finite numbers, ranges and contract limits are validated.
- Debounced candidate preview, last-night/seven-night scope, saved/candidate stage distributions and durations, quality, Watch agreement, changed-epoch strip, rule hit/fallback/shadowing counts and cleanup effects. A preview must match both the draft and its selected night window before Save is enabled. Stable sorted JSON keeps the preview task identity from changing with object-key order.
- History/revert/reset with scope confirmation; explicit JSON null for reset; desired/pending/acknowledged state and provenance. Side changes and reloads protect unsaved drafts. A preflight read detects an observed conflicting remote edit; this is not atomic compare-and-swap.
- Native model library: JSON import up to 10 MiB, local feature-contract/test-vector validation, immutable prepared document, full metadata/class-order preservation, explicit upload review, independent model selection/activation and rules fallback. The controller independently validates the exact document. Demo mode disables file upload and clearly labels its synthetic scorecard.
- Held-out `nestedSelection`/`lono` scorecards with kappa, rules comparison and per-stage recall. Training scores are not substituted; missing or out-of-range values remain missing. Preview can compare a prepared document or the stored model against rules over 1/7/30 nights, with per-night and pooled reference agreement.
- Sleep Night now offers Pod and This iPhone stage sources. The Pod route uses its returned classifier/model identity, quality and provenance; it does not silently substitute local stages on failure. Returned stage blocks retain gaps and are split into minute slices only for Watch agreement; vital readings remain separate. Health sync continues to use its existing iPhone settings.
- Late or mismatched record responses are rejected. The phone's personal model is only used for its owner's side in the main local Night/week analysis.

## Evidence so far

- `/tmp/SleepypodStageParity1.xcresult`: all 8 rule unit tests and the editor/save/history UI flow passed. The side-switch UI test expected a Cancel button, but iOS 27 uses a dismissible popover; the test was adjusted to dismiss outside it.
- `/tmp/SleepypodStageParity2.xcresult`: all 8 rule tests, 9 model tests, model selection/rules fallback UI and unsaved-side UI passed. The rule-save UI's immediate enabled assertion was transiently false; preview identity was made deterministic and the test now waits for the candidate preview to finish.
- Model/rule captures from the second run were inspected on iPhone: scrolling preserves the native cards, numeric conditions and model scorecard fit, and activation remains explicit.
- `/tmp/SleepypodStageParity3.xcresult`: all 4 Pod Night data tests and 3 editor/model/side UI flows passed. The source-switch test used a launch argument that pinned the preference, preventing the test from changing it.
- `/tmp/SleepypodStageNight4.xcresult`: all 17 rule/model unit tests and the corrected Pod/iPhone source-switch UI test passed. Stage captures are in `previews/stages/`; the light-mode Pod source screen was inspected.
- `/tmp/SleepypodStageIPad2.xcresult`: editor/save/history and Night source switching passed after replacing the menu's navigation link with a stable destination state. Updated iPad captures were inspected and copied to `previews/stages/ipad-*`.
- `/tmp/SleepypodStageLargest2.xcresult`: unsaved-side confirmation passed at accessibility XXXL. `/tmp/SleepypodStageLargest3.xcresult`: model selection/rules fallback and Night sources passed; the editor saved/reverted successfully, but its final automated scroll back to the preset exceeded the test's traversal limit. The helper now scrolls in the margin to avoid sliders and adapts to the target's position. `/tmp/SleepypodPeriodStageLargest4.xcresult`: the complete editor/save/history/revert flow passed at accessibility XXXL. Inspected largest-text captures retain wrapping and scrolling without horizontal clipping.
- Refinements add stable editor-row identities, visible condition labels, preview recall/confusion/ranges, stage durations and the Pod's reported asleep duration. A menu tap at extreme text size needed an explicit center coordinate in the UI test.

## Remaining

- Finish normal/iPad/largest-text captures, failure/retry presentation and direct model-import file-picker/device checks.
- Week/month summaries and chart sessions are now implemented; see `SLEEP_VALIDATION.md`. Advanced biometric profile workflows remain a separate Settings section.
- Integrate the coordinated Core model API, then verify fixture compatibility against its actual responses. No processor adoption, real model upload, Health-store write or live Pod actuation is established by simulator/demo tests.
- Complete other parity sections and final cross-feature QA before changing release version, archiving or uploading. Version remains 0.2.0 (7).
