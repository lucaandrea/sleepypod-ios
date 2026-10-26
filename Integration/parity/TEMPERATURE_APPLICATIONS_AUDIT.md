# Native temperature application history

26 October 2026. Native adoption of Core's optional read-only contract at `5c7601d`, documented in `docs/TEMPERATURE_APPLICATIONS.md`. This history is separate from deduplicated Shortcut command receipts.

All settings → Connections → Temperature applications uses the existing native cards and typography. It provides side selection, refresh, older pages, requested targets in the chosen degree unit, timestamp/time-zone labels, outcome/source/reason/duration and expandable audit identifiers. Accepted calls remain physically unverified; interrupted/unknown attempts remain unconfirmed. No action resends a command. Empty history and an unsupported/unavailable controller are distinct.

The client checks the advertised fixed endpoint and ready capability, issues GET requests only, bounds page payloads, validates side/order/cursors/identities/times/outcomes and freezes the controller. The workspace rejects cancelled or changed-owner replies, prevents concurrent page loads, and retains prior rows/cursor after a failed older-page read. The contract retains at most 30 days/10,000 attempts per side and does not backfill old commands or describe all DAC traffic.

Seven source-generated synthetic fixture cases use Core's actual migrated in-memory database and recorder: empty, attempting, acknowledged, unknown, two pages and the other side. The Core checkout and real hardware were not modified. Ordinary app Demo labels examples explicitly.

Validation: six focused logic/transport checks pass. Both native flows pass on iPhone (`TemperatureApplications-phone-v2`), iPad (`TemperatureApplications-ipad-v3`) and maximum Dynamic Type (`Temperature-final-AX-v5`). All 15 retained captures were reviewed. The first maximum-text run exposed a test scrolling-direction error when LazyVStack released an offscreen selector; the corrected test scrolls back toward the top. The final combined run also passes all six checks. No live Pod request is claimed.
