# Verified route selection foundation

This is tested source for explicit home/away enrollment and read-only selection.
It is **not connected to the app's saved connection or polling lifecycle yet**.
No remote gateway, phone connection, Pod setting, or controller command changed.

## Identity and credentials

`ControllerIdentityClient` sends a fresh 256-bit challenge to Core's authenticated
`GET /api/v1/connection`. The ephemeral production session refuses redirects. The
reply must retain the exact URL, JSON content type, challenge, product, schema,
and a valid installation UUID. Both declared and streamed bodies are bounded to
8 KiB. Cancellation and the personal-workspace boundary are checked around the
read. Anonymous and legacy controllers cannot enroll automatic alternatives.

The UUID identifies a persisted controller installation; a database clone or
restore can retain it. It is not hardware attestation or a replacement for TLS,
explicit origin selection, or the connection key.

`OwnerRouteVerification` validates both explicitly entered candidates before
sending either key, checks them sequentially, and requires the same identity.
Account changes and cancellation withdraw late results. `VerifiedOwnerRoutes`
stores canonical origins, stream addresses and credential digests, never keys.
Each origin must retrieve its own exact Keychain entry. Changed revision, key,
origin or invalid metadata requires verification again. The away origin must
use HTTPS.

## Selection

Keep the current route when its fresh authenticated identity matches. Only a
recognized transport failure can try the other explicitly enrolled route.
Authentication, TLS, malformed replies, redirects, HTTP server errors and a
different installation fail closed. A disabled profile, stale operation or
altered candidate cannot activate anything. A local activation failure is not
treated as a reason to retry another route. The service has no hardware methods.

```mermaid
flowchart TD
  Current[Current enrolled origin] --> Read[Fresh authenticated identity read]
  Read -->|Matching identity| Keep[Keep current transport]
  Read -->|Transport unavailable| Alternate[Read other enrolled origin]
  Read -->|Access, TLS or identity failure| Stop[Keep settings and explain]
  Alternate -->|Matching identity and current account| Candidate[Return verified transport candidate]
  Alternate -->|Any failed check| Stop
```

## Validation and remaining integration

`SleepypodVerifiedRoutes-v1.xcresult` contains 22 passing focused tests: four
identity transport tests, ten route verification/selection tests and eight
existing single-connection enrollment tests. Coverage includes challenge replay,
wrong product/version/UUID, oversized and non-JSON bodies, rejected access,
redirect status, invalid shape, changed credentials/account, per-origin keys,
disabled profiles, late results, exact-once local activation and no fallback
after access/TLS/identity errors. The signed generic simulator build passed for
arm64 and x86_64; runtime evidence is the arm64 phone simulator. Strict lint
passed.

Before enabling selection, integrate encrypted profile persistence, explicit
enrollment UI, transport cancellation and reconnection, and stable identity
scopes for the offline library, reports, learning and app-owned backup alarms.
A route change must neither erase a valid backup alarm nor expose another
account's data. Unacknowledged hardware operations must never replay. Verify
work-network/cellular access and actual device behavior separately.
