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
