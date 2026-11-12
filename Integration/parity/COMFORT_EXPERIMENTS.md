# Native comfort comparisons

This implements approved platform improvement 10 against the versioned Core
planning, feedback and execution APIs. It is a native extension of the existing
comfort and household screens; source validation is separate from distribution,
Pod deployment and attended physical qualification.

## Behavior and boundaries

- Owner and personal-account routes use their own credentials and verified
  installation/account identities. Personal routes never accept an arbitrary
  sleeper or side from the view.
- Planning and permission to control the bed are separate, expiring reviews.
  A saved comparison alone cannot issue temperature commands. The control review
  names affected zones and preserves the scheduled wake warming and vibration.
- Lost write replies require reading the saved result. Reconnection does not
  replay an authorization, Stop, feedback write or actuator request.
- Stop closes the plan before cancelling retained control permission. A partial
  Stop remains visible with an explicit recovery action. Fresh firmware readback
  can resolve the retained application state without claiming that an earlier
  command happened or replaying it.
- Revocation, account changes and backgrounding withdraw private state. Business
  errors arriving after an identity change cannot reveal the previous account's
  context. Ordinary reads cannot silently extend a control review's deadline.
- Completed-night feedback, usable observation counts and per-night exclusions
  remain distinct. Fixture feedback does not fabricate usable physical evidence.

The simulator fixture is generated from the real isolated Core planning service.
Debug-only examples are visibly labelled and cannot contact the Pod. Preview
control receipts use explicit synthetic clocks for lifecycle scenarios.

## Local validation — 12 November 2026

Built with Xcode 27.2 on iOS 27.2 simulators. Hosted Xcode 26.3 checks remain a
separate release requirement.

| Check | Result |
| --- | --- |
| Focused contracts, transport, workspace, parent-account and preview tests | 25 passed |
| Complete application tests | 1,469 passed; nine existing live-service skips |
| Complete framework tests | 182 passed; no skips |
| iPad comparison UI scenarios after review fixes | Six passed in one run |
| iPhone comparison UI scenarios after review fixes | Six passed in one run |
| Strict full-source SwiftLint | Passed |
| Unsigned physical-iOS Release build | Passed |
| Existing Python build-support tests | Seven passed |
| Updated CI workflow YAML and whitespace validation | Passed |

The first phone UI run had four passes and two failures. Test helpers searched
lazy off-screen Form rows before scrolling. After correcting those helpers,
morning feedback passed; the largest-text Stop assertion required one further
correction to search downward beneath its confirmation message. The final
targeted run passed. The final review-fix builds then passed all six scenarios
together on each device class. No application behavior or assertion was weakened
to make these tests pass. Original failed results are retained.

Local result bundles:

- `/tmp/sleepypod-native-experiments-focused-4.xcresult`
- `/tmp/sleepypod-native-experiments-regression.xcresult`
- `/tmp/sleepypod-native-experiments-framework.xcresult`
- `/tmp/sleepypod-native-experiments-ipad-ui.xcresult`
- `/tmp/sleepypod-native-experiments-phone-ui.xcresult` (original failures)
- `/tmp/sleepypod-native-experiments-phone-ui-corrected.xcresult`
- `/tmp/sleepypod-native-experiments-phone-large-final.xcresult`
- `/tmp/sleepypod-native-experiments-phone-review-fixes.xcresult`
- `/tmp/sleepypod-native-experiments-ipad-review-fixes.xcresult`

The full application/framework suites ran before the three presentation fixes;
the final UI suites, strict lint and Release build ran after them. The fixes
distinguish a saved plan from ended control permission, name the account-appropriate
qualification destination and restore the existing destructive Stop color. Both
owner and personal qualification instructions have screenshot coverage. Theme.red
contrast against the group background is 4.78:1 in light appearance and 5.22:1 in
dark appearance.

CI reuses the existing comfort editor's iPhone/iPad build jobs and adds the six
comparison scenarios without removing the existing standard/large-text checks.
Screenshots cover planning, control review, feedback, error/loading states,
missing qualification, lost replies, partial Stop, readback recovery and stopped
state, with light/dark, largest text and tablet landscape examples.

## Hosted runner availability

Several macOS arm64 UI jobs on the consolidated release ended before executing
test steps. GitHub annotations on jobs `131178721780` and `131130324164` report
that a runner was not acquired after multiple attempts and identify macOS arm64
capacity constraints. These cancellations are retained; they are not test passes.

All nine UI workflows now explicitly use the standard `macos-15-intel` runner,
which the existing offline-library workflow already used successfully. Workflows
that transfer a built test bundle keep the builder and every consumer on the same
architecture. Xcode 26.3, test scenarios, assertions and timeout limits remain
unchanged; the comfort workflow additionally runs the six new comparison cases.

The runner is listed in [GitHub's hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
and its [published image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
lists Xcode 26.3 and the relevant iOS simulator runtime. Local workflow parsing
and all seven build-support tests pass. This change does not guarantee hosted
capacity or replace the new revision's hosted checks.

## Independent review

The first independent native review returned three material findings. After one
fix batch, the same reviewer independently validated all 29 corrected individual
captures and scored F1 (ended permission versus saved plan), F2 (qualification
navigation) and F3 (destructive Stop appearance) resolved, with disposition
`ship`. This verdict covers those three fixes; it is not physical-device,
VoiceOver, live-account or cross-platform acceptance. Review receipts remain in
the local `.impeccable/review/comfort-experiments/` directory.

This is an extension of the incumbent native Form, typography, colors and
navigation. It does not replace the visual system or alter design-system files.

## Remaining acceptance

Hosted validation, merge and TestFlight distribution remain separate steps.
No Pod restart, experiment activation,
household transition, routine edit or physical command occurred during this
implementation. Attended cancellation/reversion checks and prospective nights
must establish the physical behavior and any comfort benefit.
