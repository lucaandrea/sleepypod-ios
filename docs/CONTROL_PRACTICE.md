# Learn the controls and join a personal account

Approved improvement 18 extends the existing browser tutorial into matching native
lessons. Owner Settings and the personal account open the same independent SwiftUI
practice screen. The selected controller can also open the existing illustrated
browser guide through an explicit link.

The lessons use the same initial examples as Core: a 76°F target, a saved 07:00
wake and a proposed 08:00 wake. Each cooler/warmer tap immediately changes the
example's requested target, matching the real native plus/minus controls. The
lesson distinguishes that request from water temperature reaching the target.
An alarm edit withdraws its previous review; saving requires the exact reviewed
time. Warming is shown 30 minutes before the example wake, including midnight
wrap. Power off and its power symbol stop heating/cooling; Stop vibration is a
separate action, matching the real native controls. Stopping does not
delete the saved alarm. Skipping is not completion; Restart and leaving discard
the example.

These examples make no hardware, account, storage or AI requests. The practice
screen receives only an optional public-guide URL, not a live control workspace.
It uses native navigation, grouped forms, a time picker, SF Symbols and existing
theme tokens. All copy follows Dynamic Type; native navigation and transitions
retain the system's accessibility and reduced-motion behavior.

## Joining without typing an address

1. The existing sleeper shares a personal invitation link from their account.
2. The new sleeper opens Settings → Personal account → I have an invitation,
   then Join with an invitation.
3. They paste the complete link, tap Review invitation, and check the controller
   shown. No request is made during that review.
4. They enter their own name, acknowledge the account preparation, and tap Join
   account. The existing personal-account transport then exchanges the single-use
   invitation for a separately generated device secret.

The link uses Core's existing `/household/index.html#invite=…` format, so the same
link works in a browser. The native share action now supplies that complete link.
Native universal links are not configured; this implementation deliberately
uses the system Paste button rather than claiming that tapping a web link opens
the native app. Separate address/code entry remains available for older invitations.

The parser accepts only the exact invitation path and a single valid invitation
fragment. It rejects embedded credentials, queries, extra/duplicate fields,
unsupported schemes, malformed/oversized secrets and encoded path substitutions.
Existing endpoint policy requires HTTPS remotely and permits HTTP only on local
addresses. The destination is reviewed before the first request, and the personal
transport refuses redirects and never reads the owner's connection key.

Editing an invitation withdraws its local review. Backgrounding or dismissing
the form clears an unsubmitted link, code and acknowledgment. Once Join is
submitted, the existing Keychain pending-request and reconciliation machinery
preserves uncertain outcomes without generating a second account or sending a
different request. Expired/revoked/claimed invitations tell the sleeper to request
a new one. Joining alone does not assign a side or activate routines.

## Acceptance

The focused model tests cover immediate target requests, bounds, review invalidation, strict times,
midnight wrapping, independent Stops, reset and completion. Invitation tests cover
browser/native round trips, rejection cases, draft withdrawal and an explicit
personal join with no owner-key access.

The phone/tablet UI suite exercises owner and personal entry, the complete three-
lesson journey, skip/reset/return, dark maximum text, iPad landscape, invalid links,
background clearing and expired-invitation recovery. The local iOS 27.2 phone run
passed 21 checks and the iPad run passed seven, with no failures or skips. The
build-for-testing, project strict SwiftLint and diff check passed. The simulator
results retain two Invalid frame dimension runtime warnings per run; their source
is not established by these focused checks.

An independent full review identified three corrections: match immediate native
temperature taps, teach the actual power/Stop controls, and improve required-copy
contrast on elevated sheets. All three were fixed together. The reviewer then
scored all three resolved after inspecting 37 fresh captures and checking source
hashes. Measured required-text contrast ranged from 11.797:1 to 18.861:1. Existing
Theme tokens and native controls are preserved. The original evidence and failed
review remain distinct from the passing corrective evidence.

Hosted iOS 26 workflow execution, TestFlight, actual household pairing and physical
use remain separate gates. A simulator pass does not establish those results.

No real Pod, phone account, routine, side assignment or home accessory changed
during this implementation.
