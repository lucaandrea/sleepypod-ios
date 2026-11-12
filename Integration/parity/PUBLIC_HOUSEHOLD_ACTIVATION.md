# Public arrangement activation and recovery

Core now projects the attended coordinator's availability through the existing
session and side-review contracts. The native app uses that capability; it does
not infer readiness from occupancy or enable a controller deployment option.

The existing attended screens cover independent review, activation, one restart,
verified recovery and fresh account reload. This change closes two recovery gaps:

- A completed cancellation remains visible, while a different later approved
  review can begin a distinct attended attempt. Earlier reviews, the same review
  and unavailable/held admission cannot be used.
- An uncertain activation with no saved receipt stays in read recovery. Neither
  the screen nor the workspace offers or submits another activation in that
  maintenance session.

The contract/workspace suite passed 19 tests, including three new regression
cases. Strict project lint and simulator build passed. All eight distinct iPhone
maintenance scenarios passed across the initial and corrective runs; four iPad
scenarios passed together. The retry test initially scrolled the wrong way after
navigation replaced the form. Its final phone and tablet runs passed with the
same assertions and time limits. Original failed results remain retained.

An independent finish review inspected all eleven final phone/tablet captures,
verified the source and attachment hashes, and returned `ship` without material
findings. This is simulator and rendered-state evidence, not hosted or physical
acceptance.

The implementation does not activate Luca/Marissa assignments, change routines,
restart a real Pod, train personal models or establish physical acceptance.
Source, simulator, TestFlight and live two-person qualification remain separate.

## Consolidated release correction — November 11

Hosted run `43160797555` exposed a real review-time limit: the keep-solo preview
was opened at 05:44:10 UTC and confirmation tapped at 05:45:28, after its 60-second
client deadline. The app now fetches a fresh cancellation preview at confirmation,
requires the identical reviewed control digest, operation and account revisions,
and validates the new observation with the original 15-second freshness limit.
Changed controls require another review; stale observations, identity changes and
backgrounding still prevent submission. No request is automatically retried.

All 34 focused contract/transport/workspace/boundary tests and both original
failing iPhone UI paths passed locally. The preparation UI test now scrolls to
the actual draft controls instead of assuming they are already onscreen.

The hosted maintenance batch also exhausted its 20-minute execution budget after
five completed scenarios. CI now builds one ad-hoc-signed bundle and verifies its
source revision and Xcode version before each isolated phone/tablet group. All
eight maintenance scenarios appear exactly once, and the complete side-review
and preparation suites remain selected. Each group retains a 20-minute limit;
the original failed results remain evidence, not passing acceptance. Hosted
verification of this correction is still required.
