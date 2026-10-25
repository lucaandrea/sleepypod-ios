# Title

feat: preserve Sleepypod UI and add native control and sleep parity

# Description

Keep Sleepypod’s Temp, Schedule and Sleep presentation while integrating the retained personal comfort, routines, coaching, Health, Home and Shortcuts services. The retired Free Sleep shell, views and asset catalog are excluded from the build.

Add native Stage and temperature scales, articulated base controls and schedules, alarm and curve editors, Night/Week/Month summaries, source-aware biometrics and Watch references, range exports, room and recent-sleep context, and remote stage rules/model workflows. Scope Health rebuild cleanup to the selected Pod/side and preserve earlier data when analysis is incomplete. Preserve controller capabilities, conflict checks, explicit hardware actions, provenance and missing-data states.

```mermaid
flowchart LR
  UI[Sleepypod native UI] --> Controls[Temperature / Base / Schedule]
  UI --> Sleep[Sleep / Biometrics / Stage models]
  UI --> Personal[Personal feature editors]
  Controls --> Core[Core API]
  Sleep --> Core
  Personal --> Services[Retained native services]
```

Validation: 369 local unit tests and the chart interaction flow pass; five live-Pod tests skip without a configured controller. Native presentation/import guards, strict SwiftLint and the contract package build pass. The new context flows pass on iPhone, iPad and maximum Dynamic Type; all 15 Health lifecycle checks pass. Per-feature iPhone/iPad/accessibility evidence and remaining work are recorded under Integration/parity.

This is a tested integration checkpoint. Full web parity remains in progress, with no new TestFlight upload or release-version change. Build 0.2.0 (7) release evidence is retained separately.
