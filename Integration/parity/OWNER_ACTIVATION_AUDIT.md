# Native owner qualification and activation

The coordinated controller added this workflow in Core PR #44, merged at `41d6f9389bffb6448d06f49584a810cabfbe97a1`, after the earlier parity checkpoint. Settings → Personal comfort → Qualification & activation exposes the additive `features.ownerActivation` workflow in Sleepypod's grouped cards, native navigation and typography.

## Behavior and contracts

- Reads `/api/v1/comfort/owner` for the selected side. Shows controller identity, six attended checks, matching reviewed nights, eligibility reasons and current owner activation. Stored Active mode alone is not displayed as an authorized grant; native uses `activation.current`. Stop remains available for Active and Preview. Editing an Active configuration explicitly explains that saving ends its grant.
- `POST /owner/prepare` captures a qualification, activation or uncertainty-resolution review. The native request sends the side, purpose and explicit nullable check kind. The server supplies all evidence. The review keeps command acknowledgments distinct from the owner's physical observations, shows the exact bounded policy and matching nights, and expires within sixty seconds.
- `POST /owner/confirm` sends only the prepared review ID, side, explicit consent and trimmed note. The client does not invent observations, night counts or qualification evidence. It validates side/purpose/identity, complete qualification, matching policy and seven eligible nights. The server remains responsible for source-backed qualification and current dispatch authority.
- `POST /owner/retest` binds the exact recorded check ID. Retest revokes activation. Recovery preserves the uncertain command and returns to Preview with a six-hour pause; it does not replay the command or claim delivery.
- Connection, side and scene changes discard reviews. Network latency is subtracted from review lifetime; expiration and clock rollback cannot reopen consent. Unknown mutation responses require explicit readback and are never automatically replayed. Responses are bounded to 1 MiB, bypass caches and use the origin-scoped owner transport. Authentication errors do not expose response bodies.
- Demo is visibly synthetic. It can inspect the qualification, seven-night activation and recovery examples, but confirmation and retest are disabled and the demo client rejects those mutations.

## Source evidence and verification

`generate-comfort-owner.ts` reuses Core's isolated in-memory `ownerFixture`, replacing only its test spy with a no-op and resolving imports into the pinned clean checkout. The actual production owner service produces seven status cases and qualification/activation/recovery review records in `comfort-owner-example.json`. The generator verifies the Core revision and working tree remained unchanged; it starts no controller or hardware services.

Twelve owner logic/transport checks pass, including preparation latency, expiration, clock rollback, explicit consent, uncertain responses, retest revision and connection invalidation. Existing personal-comfort and sensor-calibration regressions also pass. Both owner walkthroughs pass on iPhone and iPad, and the final expandable-night-list flow was rerun on each. Both final flows also pass at maximum Dynamic Type.

| Result bundle | Verified scope |
| --- | --- |
| `ComfortOwner-phone-v4` | Both phone walkthroughs before the night-list refinement |
| `ComfortOwner-ipad-v6` | Twelve owner logic/transport checks and both iPad walkthroughs |
| `ComfortOwner-AX-v8` | Both final walkthroughs at maximum Dynamic Type |
| `ComfortOwner-phone-v9` | Final phone activation, expandable nights and recovery |
| `ComfortOwner-ipad-v10` | Final iPad activation, expandable nights and recovery |

All 27 final captures in `previews/owner-activation/` were visually reviewed. Normal phone text size was restored. The earlier combined run completed every unit/transport test and the maximum-text replay chart, then was deliberately interrupted to refine the owner review layout; its overall interrupted result is not presented as a passing run. The focused runs above supersede that interrupted owner walkthrough.

The initial UI runs identified inherited test-side selection and an iPad swipe aimed at the background. Tests now select Left explicitly and address the visible scroll area. The final night list is expandable, keeping consent reachable while preserving inspection of every matching night.

No actual attended check, owner activation, physical command, outage trial or qualifying overnight observation has been performed by these tests.
