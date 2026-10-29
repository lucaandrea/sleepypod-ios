# Native personal-account preparation

This is preparation for separate personal accounts, not support for two active sleepers. The existing owner app remains the default. No Pod deployment or TestFlight release is part of this change.

## Entry and ownership

Settings → Personal account explains the preparation stage. Owner entry/setup requires the optional `/api/v1/capabilities` feature `features.householdPreparation` to report `implemented: true` and `runtime: "ready"`. Missing or disabled features keep owner setup inactive. An invitation holder can enter the separate join screen from Settings or first-launch onboarding; the server still enforces its runtime gate.

Opening personal preparation replaces the Temp/Schedule/Sleep tabs. It suspends owner requests, sockets, Shortcuts, background Health work and microphone capture. An app restart retains this boundary. The installation owner connection remains separate; returning to it is an explicit action protected by local device-owner authentication. Closing a personal session stays in the personal shell and keeps that device paired. Revoking a device removes its credential and private cache from this phone. A remote 401 on an established personal connection does the same.

## Supported preparation actions

- Set up an owner personal account, explicitly choosing which existing side's routine to copy.
- Join with a new-person or own-device invitation. A new person remains unassigned.
- Save personal temperature units, preferred temperature, comfort and wake-time sharing preference. Cloud analysis stays off.
- Save a complete weekly routine draft, including power, temperature phases, alarms, snooze and notes. Bedtime nights preserve the existing week/overnight validation. No live schedule endpoint is used.
- Create a personal invitation (owner only), pair another own device, list/revoke issued invitations and list/revoke own devices. The last device cannot be revoked by the controller.

Assignment activation, personal controls, personal sleep history and personal Health import remain unavailable. Drafts are explicitly labelled **Draft only**. Joining never moves the owner out of the currently active side.

## Credential and retry contract

The client generates 32 cryptographically random bytes for each device/invitation secret and encodes them as base64url. Credentials, private drafts and exact uncertain requests live only in a `WhenUnlockedThisDeviceOnly` Keychain item. Saved connections have distinct UUIDs and are pinned to the verified Pod/household/account/sleeper identity. They do not use the installation-owner token namespace.

A write is persisted before it is sent. Unknown outcomes retain the original payload and credential. Setup/join can be reconciled with GET session; an explicit retry reuses the exact payload. Conflict responses require a refresh. A draft based on an older revision requires explicit review before it can replace refreshed values. Identity changes hide private data instead of adopting a different account's response.

The personal HTTP client permits only the preparation-v1 household and `me/preferences`/`me/routines` routes, rejects redirects and never sends cookies or a borrowed owner token. Owner authorization is passed explicitly for initial setup only. Native logout does not use browser cookie endpoints.

## Verification

`Integration/Fixtures/household-preparation-v1.json` is copied verbatim from Core's frozen fixture. Contract, transport, lifecycle and isolation tests cover uncertain request recovery, stale draft revisions, exact weekly payloads, revocation, signout during an in-flight read, changed identities, capability gating and zero legacy Health/control calls in personal mode.

`--household-fixture` is a Debug-only simulator fixture with an in-memory vault and no network transport. UI tests inspect the unassigned member shell and private preference/routine editors on iPhone and iPad. It is not proof of a live account, device pairing or physical-bed behavior.
