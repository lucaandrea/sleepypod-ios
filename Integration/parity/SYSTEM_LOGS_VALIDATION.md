# Native System logs

Implemented on 2026-10-25. This is one System capability; the full parity program and TestFlight release remain in progress.

## Coverage

Both native log entry points now use the same Sleepypod screen. It discovers Core's current service inventory and active states, supports journal priority ceilings, 50/100/200/500-line limits, case-insensitive text filtering, Follow/Pause, explicit refresh, local-only expiring clipboard copy, and plain-text file export. Follow polls every five seconds while foregrounded; service inventory refreshes every thirty seconds. The existing firmware console remains available.

Changing service, level or line limit clears the old snapshot immediately. A late response cannot replace a newer query. Failed refreshes retain a labeled previous snapshot and disable copy/export until a successful refresh. No service selected, empty results and unavailable sources have explicit states. Journal parsing preserves timezone colons; display formatting can expand structured JSON without changing the original copied/exported lines. Severity colors are derived from message text because the short-ISO endpoint does not include structured journal priorities. Filtering itself uses the controller's journal priority parameter.

## Contracts and validation

Inspected Core `src/server/routers/system.ts` and `src/components/status/SystemLogViewer.tsx`. Reads use GET `/api/system/log-sources` and GET `/api/system/logs` through the configured owner connection. Unit names and line limits are validated before transport. Demo logs are labeled synthetic and issue no Pod requests.

- Seven model/transport cases passed in `Logs-phone-final.xcresult`: timestamp parsing/raw preservation, severity fallback, structured JSON display, local input rejection, exact GET routes/queries, source/priority/text filtering and export selection, and stale-response suppression.
- The full source → priority → search → copy → export-picker flow passed on Dark iPhone, maximum accessibility text and Light iPad. Results live in ignored `build/parity-validation/Logs-phone-final.xcresult`, `Logs-accessibility-final.xcresult` and `Logs-ipad.xcresult`. Final accessibility captures additionally reveal the matching row and wait for native text transitions.
- Export verification opens and dismisses Apple's Files picker with the selected log document. It does not claim a saved archive on a physical iPhone or a live log export.
- The first two UI attempts failed because iOS 27 exposes the picker's Cancel affordance as an accessibility Other element rather than a Button. The query was corrected after inspecting its hierarchy and rendered picker; product behavior was unchanged.
- Retained screenshots in `previews/system-logs/` cover the filtered log and system export picker on each form factor. Strict SwiftLint, the compiled presentation guard and diff whitespace checks passed before publication.

Owner PR/CI merge: pending publication. No live controller commands, TestFlight upload or physical firmware-console acceptance are claimed.
