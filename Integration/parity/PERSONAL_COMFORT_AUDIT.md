# Native personal comfort and Preview reports

October 26, 2026. Native implementation and simulator checks complete; not a release or physical qualification claim.

## Contract and presentation

Core source: `27736f9eac59eda6366df0645a78bbb35efc85eb`, `src/comfort/contract.ts`, `signals.ts`, `bedtime.ts`, `report-contract.ts` and `src/server/routers/comfort.ts`. The old `native/v1` compatibility prefix is still absent. Native calls the authenticated `v1/comfort` routes directly, gated by the returned optional features. The new pages use Sleepypod's existing grouped cards, type, colors and navigation.

- Read status, fault, runtime, current decision, learned offset, manual pause and recent observations.
- Draft Off/Preview, Fahrenheit range, qualified Pod sensor guard and bed-entry timing. Preview never sends a hardware command; Active remains unavailable.
- Guarding may withhold proposals based on qualified Pod estimates. Apple Health remains a separate comparison source. Bed entry is not measured sleep onset; only intermediate temperature phases may shift, at most 30 minutes. Power and alarms remain fixed.
- Record warm/cold/comfortable check-ins for the Pod's current local date or prior fourteen calendar dates. The phone timezone does not shift those labels.
- Present authoritative report-list night counts, not a sum of item flags. Review actual evidence, recorded intervals, proposals, reasons, gaps and paged observations.
- Bind a review to the exact report digest and expected prior review ID (explicit JSON null for a first review). Default to retest; actual-night confirmation is explicit. An evidence change while paging discards the prior page and requires refresh. Reviews never unlock Active.
- Freeze the controller and side for each operation; invalidate old responses and unsent preflight changes. Configuration saves compare the current configuration before dispatch. Unknown writes require explicit refresh and are never replayed.
- Ordinary Demo has no overnight reports. The explicit DEBUG example has zero qualifying intervals, remains non-reviewable as an actual night, and never increases the owner-confirmed count.

## Validation

`Integration/Fixtures/personal-comfort-example.json` passes the current Core `comfortStatusSchema` and `previewReportDetailSchema` validators.

- Twelve focused checks pass: configuration/capabilities, Pod calendar dates, Demo isolation and retained check-ins, exact review digest/revision and explicit null, changed cursor/evidence, preflight conflicts, owner invalidation and non-replaying recovery, plus all six REST routes and request bodies.
- Both interaction flows pass on iPhone, iPad and maximum text: Preview with sensor/entry guards and a check-in; paged report, explicit retest review and returning to the night list with the saved label and zero qualifying Demo nights.
- `Comfort-phone-v2` first validated both flows and eleven checks. `Comfort-ipad-v3` validates twelve checks and both flows. `Comfort-accessibility-v4` validates both flows. The long review menu was then replaced with a wrapping labelled menu; the report flow passes again in `Comfort-controls-phone-v5` `Comfort-report-accessibility-v6` and `Comfort-report-ipad-v7`.
- Thirteen captures per device are retained under `previews/comfort`. The wrapping review control is inspected at maximum text. Strict SwiftLint and the compiled presentation guard pass. The same source also passes an unsigned generic-iOS device build.

No live feedback, configuration or review has been posted. The mode-only Shortcut mapping is tracked with the remaining personal API reconciliation; it must use a server-side mode-only update, without overwriting concurrently changed limits.

Complete the native routine, history/Health/coach mapping and final parity checklist before the release build. Controller migration, physical operation and real overnight qualification are separate from simulator validation.
