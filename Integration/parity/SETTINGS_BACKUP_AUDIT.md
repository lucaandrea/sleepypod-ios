# Backup settings parity

Status: native implementation, nine focused logic/transport checks, and complete iPhone/iPad/maximum-text interaction flows pass. The final maximum-text capture is being refreshed after shortening the Save label. This does not establish live archive delivery or completion of the wider release.

On 2026-10-25, compared Core `SettingsScreen.tsx`, `ArchivePushSettingsForm.tsx`, `routers/archivePush.ts`, and the existing native `CoreSystemDatabaseClient`.

## Actual web scope

The web Backup section configures nightly SSH archive push. It has enabled, host, port, remote user, remote path, raw/database inclusion, Save, SSH public-key generation/copy, and a saved-configuration connection test. Its source does not provide an archive run-now button, archive delivery history, or a separate archive status endpoint. The systemd timer performs the push. The preliminary checklist has been reconciled with this actual source scope.

The native Databases screen already streams the supported online SQLite archive download through `/api/db-backup`. System Storage handles local retention/cleanup; these remain separate operations.

| Operation | Exact route |
| --- | --- |
| Read config plus public key | GET `/api/archive-push/config` |
| Save complete config | POST `/api/archive-push/config` |
| Generate/read public key | POST `/api/archive-push/key`, `{}` |
| Test saved target | POST `/api/archive-push/test`, `{}` |

The complete config is `{enabled, host, remoteUser, remotePath, port, identity, include}`. The controller-supplied identity path is preserved; the web does not edit it. Key generation returns `{publicKey, generated}` and does not export a private key. Connection testing uses saved configuration, may record a first-use SSH host key, and does not prove a successful archive delivery. Empty inclusion is accepted by writes but normalized to both datasets by current reads; the native editor requires at least one selected dataset.

## Native behavior

Existing Sleepypod cards and grouped settings navigation contain the destination editor, public-key copy/share and saved-destination test. Read failures do not synthesize editable defaults. Drafts survive read failures; a fresh full-snapshot comparison detects observed remote edits before replacement. This is a client preflight, not an atomic server compare-and-swap guarantee. Acknowledged configuration writes, key generation and connection-test receipts remain distinct. Unknown write outcomes require readback and are never automatically replayed. Tests require saving or discarding edits first, and a result belongs only to the tested configuration.

The existing database-download screen is linked separately. No private key leaves the Pod. Validation uses simulated identities and `.invalid` destinations; no live SSH connection or key generation was performed.

## Validation

- `ArchivePush-phone.xcresult`: eight workspace/conversion checks, one exact-route transport check and the original phone UI flow passed.
- Maximum-text testing caught test cursor placement and a tap hidden beneath the navigation bar. Inputs now expose a usable Clear action, scrolling dismisses the keyboard, and the UI driver respects the visible navigation boundary. `Settings-device-units-backup-accessibility.xcresult` passed the complete corrected Backup flow plus twelve independent Device unit/transport checks.
- `Settings-backup-device-phone.xcresult` and `Settings-backup-device-ipad.xcresult` pass the complete final Backup flow (alongside the first Device flow). Reviewed phone/dark, iPad/light and maximum-text captures are in `previews/settings-backup/`. Earlier failed or superseded captures are not acceptance evidence. Strict SwiftLint, diff checks and the presentation guard pass. Version remains 0.2.0 (7).
