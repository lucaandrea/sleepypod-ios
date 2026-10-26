# Native automation alert inbox

2026-10-26. Based on coordinated Core PR #28 / `7fa390a75ce3358e39d59ac016b66c0d38144ac3`, `docs/AUTOMATION_NOTIFICATIONS.md`, notifications contract/foreground functions and router. No real notification publication, outbound webhook, hardware mutation or APNs delivery was performed.

Settings and Autopilot share one owner-scoped inbox. Foreground reads run every five seconds. Initial connection establishes a high-water ID without announcing old alerts; later reads announce only new unread/unexpired rows. Restored databases and clock rollback cannot lower the cursor. Changing backend, saved origin or connection credentials resets the session; late prior-session replies cannot populate the new inbox. Delivery uses an in-app banner/VoiceOver announcement only, independent of the existing NotificationRelay and its optional external webhooks.

The inbox preserves plain-text messages, read/expired states and paginated history. Opening it never acknowledges alerts. An explicit selection of at most fifty IDs is reviewed before acknowledgment; an uncertain response keeps exactly those IDs for safe idempotent retry or readback. Newly arriving alerts are excluded. Receipt ID sets must exactly cover the request without overlap. Missing retained IDs are reported separately.

Server generation time plus local elapsed time governs expiry; phone epoch is not assumed to match the Pod. Failed reads keep history while withholding current badges/announcements. Background, reversed local time and reads older than fifteen seconds also withhold live status. Acknowledgment invalidates the old global badge until a subsequent read. History pages do not refresh live freshness or produce announcements.

The ordinary Demo inbox is empty/unavailable. A separately opened synthetic example exercises selection and history in memory and is clearly labeled. It cannot publish real alerts.

## Validation

- `Alerts-phone-v1.xcresult`: ten focused model/lifecycle/REST checks pass, plus the native inbox flow in 22.724 seconds. Checks cover initial/new/rollback delivery, Core-generated cursor equivalence, server-clock expiry, stale/error/background withholding, pagination, frozen acknowledgment retries, readback, malformed receipts, scope isolation and late reads, bounded response validation and exact REST bodies.
- The iPad test initially asserted an expired label during the deliberate post-acknowledgment freshness gap. It now waits for the confirmed global unread count. `Alerts-ipad-v2.xcresult` passes in 23.577 seconds; maximum text `Alerts-accessibility.xcresult` passes in 64.510 seconds.
- All twelve captures are reviewed under `previews/alert-inbox/`; messages wrap and the selection/history controls remain reachable. Strict lint, diff checks and the native-presentation guard pass.
- `alert-inbox-core.json` is generated from the recorded Core commit’s pure schema/foreground functions with synthetic rows. Expected high-water IDs are 3, 5, 5, 5, 6; announcements are none, 5, none, none, 6. No database or personal alert content is used.

GitHub checks remain pending for this feature. App version/build remain 0.2.0 (7); full parity, physical qualification and TestFlight delivery remain separate unfinished work.

A later scalability pass uses a lazy stack for up to 1,000 retained alerts. The full phone selection/acknowledgment/history flow passes again in `Room-phone-v4.xcresult` (25.429 seconds). The test taps the visible switch control explicitly; the first lazy-list run tapped its label without changing selection and failed before acknowledgment. No product acknowledgment was sent in that failed attempt.
