# Native controller Updates

2026-10-26. Native Settings cards and the Temp / Schedule / Sleep shell are retained. App version/build remain 0.2.0 (7); no controller update, firewall mutation or release upload was performed for validation.

## Source and behavior

Inspected Core’s UpdateCard.tsx, SystemInfoCard.tsx, system router and sp-update. Coordinated Core PR #33 merged at `e6ace9fe64348ad661440e02276b52d86f8ae4e3`. The controller selects its repository from root-owned `/etc/sleepypod/github-repo`; the client cannot choose it. Native update dispatch requires the response schema’s repository field, withholding the operation on older upstream-only updaters.

The previous upstream GitHub checker and green “up to date” result on failed reads are removed. Settings now reads the actual installed branch, commit, title, build date and optional version. Stable/main and development/dev are explicit choices; unknown branches require choosing. Refresh is read-only. The server exposes no remote latest-build comparison or percentage progress, so neither is invented.

Review captures the installed build and internet state. It expires after five minutes; dispatch rechecks both and the installed-repository capability. When internet is blocked, temporary access requires explicit consent. The app does not pre-unblock the firewall: sp-update saves, opens and restores its original rules. Storage remains reachable from Updates.

An atomic protected controller-scoped record is written before the non-idempotent update POST. A missing/malformed response, reopening or a competing screen never automatically repeats the update. Read-only foreground observation checks the installed build and network. An unchanged build after a connection gap is only a reconnection; a known changed identity on the requested branch is a changed build, not physical qualification. After three minutes an unresolved observation remains unconfirmed, with manual status checks available.

Original local-only state and unknown network restoration survive reopening. Restoration is an explicit reviewed action with pre-read and confirmation readback; a lost reply does not cause unnecessary repeats. Removing tracking only removes the local observation, never claims cancellation or silently changes networking. Unreadable local records block updates until reviewed recovery and cannot erase a readable request.

## Validation

- `Updates-phone-v1.xcresult`: all 13 lifecycle/model/REST checks pass. They cover consent, changed preflight, expiry, persistence-before-dispatch and write failure, lost replies across reopening, unchanged/wrong-channel builds, timeout, network readback/retry, malformed receipts, unreadable storage and competing views. Route and body assertions include bounded OpenAPI response references.
- The first UI run exposed duplicate nested accessibility nodes in the iOS 27 confirmation popover. The test now selects the first matching system button; this changes no product behavior.
- `Updates-phone-v2.xcresult`: the full review/consent/dispatch/reconnect/network/dismiss flow passes in 39.447 seconds. `Updates-ipad.xcresult` passes in 33.410 seconds with light appearance. Eight captures have been reviewed under `previews/controller-updates/{phone,ipad}`.
- `Updates-accessibility.xcresult` passes the same flow in 90.858 seconds. All twelve final captures are reviewed; descriptions and controls wrap and scroll at maximum text. Strict lint, diff whitespace checks and the built-app presentation guard pass. PR #27 passed all four GitHub checks (build, contract-test, lint and done; run 40299557735) and merged into owner main at `d655af38653f22097f89e9c863e9a52582d149d3`. Its feature branch is removed.

Demo changes only an in-memory synthetic controller. Lifecycle tests establish state handling, not a real update, firewall restoration, hardware readiness or TestFlight delivery.
