# Native connections settings parity

Status: implemented and locally validated; publication checks pending. No live bridge or network change has been made.

## Audited contracts

Core `HomeKitConfig.tsx`, `MqttSettingsForm.tsx`, `routers/homekit.ts`, `routers/mqtt.ts`, `homekit/index.ts`, and `streaming/mqttBridge.ts` were read on 2026-10-25. The coordinated Core chat owns server changes.

| Capability | Native request |
| --- | --- |
| HomeKit state and pairing | GET `/api/homekit/status` |
| Enable or disable the bridge | POST `/api/homekit/enabled`, `{enabled}` |
| Reset pairing after review | POST `/api/homekit/unpair`, `{}` |
| Resolved MQTT settings and field sources | GET `/api/mqtt/settings` |
| Save MQTT configuration | PATCH `/api/mqtt/settings` |
| MQTT run state and publishing | GET `/api/mqtt/status` |
| Test a broker without saving | POST `/api/mqtt/test-connection` |

Core `InternetToggleCard.tsx` is the complete web Network section. It provides a reviewed internet-access toggle, current blocked/allowed state and errors. Native adds a visible Network route using the existing `StatusManager` freshness/serialization guards and matching-response validation; it retains the developer shortcut. It does not imply that an allowed firewall proves upstream connectivity.

| Network operation | Existing native transport |
| --- | --- |
| Read internet access | `system.internetStatus` |
| Reviewed access change | `system.setInternetAccess`, `{blocked}`; returned state must match |

## Implementation requirements

- Preserve existing native Apple Home controls. Add separate native HomeKit bridge and MQTT routes under Connections using existing Sleepypod components.
- HomeKit: enabled/running/transitioning status, paired-controller count, setup code and bounded local QR decoding; hide pairing material when its observation is stale or failed. Serialize changes, invalidate earlier polls, and show uncertain outcomes without automatic mutation retries.
- Pairing reset requires an explicit in-app review explaining identity/code rotation and removing old bridge tiles from Apple Home. Tests use demo identities only.
- MQTT: enabled, broker URL, username, write-only password, topic prefix, Home Assistant discovery and TLS. Distinguish stored, environment and default sources. Blank replacement password preserves the saved secret. Keep edits stable during status polling.
- Test connection uses the entered credentials. The current Core router does not reuse the stored password when it is omitted; explain this in the native form rather than implying a saved-password test.
- Core passes the URL unchanged to mqtt.connect. Require a secure URL scheme when TLS is selected; a boolean alone does not establish encryption. Certificate policy remains controller-owned.
- Separate configuration save receipts, connection-test receipts and live bridge state. A saved configuration does not prove a broker connection or a physical command effect.
- Validate exact request bodies, failure/cancellation/race behavior, stale states and responsive iPhone/iPad/largest-text interactions before merging. No release until the broader parity audit completes.

## Validation

`Connections-phone.xcresult`: 28 focused unit/transport checks pass (24 XCTest and four Swift Testing). They cover exact routes and secret omission, HomeKit observation/mutation races, MQTT draft conflicts and unknown outcomes, secret clearing when a late test returns, and existing network freshness/readback contracts. Its first HomeKit and Network UI checks expected a Cancel button; iOS 27 uses a dismissible popover. The test now exercises dismissal without assuming that button exists.

`Connections-phone-reviewed.xcresult`: all three final iPhone flows pass. The HomeKit setup code/QR and reset review, MQTT edits/test/save/TLS validation, and reviewed network toggle were captured and visually inspected. All three flows also pass in `Connections-accessibility-reviewed.xcresult` and `Connections-ipad-reviewed.xcresult`. Visual inspection found the largest-text HomeKit code splitting its final digit; it now scales as one readable line. The complete HomeKit flow passed again on all three layouts in `Connections-HomeKit-{accessibility,phone,ipad}-final.xcresult`, with the full QR visible. Thirty-six reviewed captures live in `previews/settings-connections/`. Strict SwiftLint, diff checks and the presentation guard pass. Version remains 0.2.0 (7); CI and merge are recorded below.

## Integration

PR [#12](https://github.com/lucaandrea/sleepypod-ios/pull/12) merged to owner main at `52c94b2fa1ed8462459bab7eef3abf406baefa3d` on 2026-10-26 04:17:40 UTC. CI run `40267343313` passed build, lint, contract-test and done. The merged feature branch was deleted locally and remotely.
