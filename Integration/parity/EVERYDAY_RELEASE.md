# Everyday controls release

This native release brings the approved Tonight overview, automatic comfort range,
Watch recording assistant, learning journey, clear wake plan and bed-care center
into one app revision. It preserves the encrypted owner offline library already on
main. The individual contract and validation records remain in this directory.

| Surface | Behavior | Remaining acceptance |
| --- | --- | --- |
| Tonight | Independently fresh mode, target range, actual wake occurrence and morning report entry | Live controller and distributed-app walkthrough |
| Comfort range | Reviewed automatic bounds with an explicit wake exception | Live policy acknowledgments and existing adaptation gates |
| Watch recording | Provenance-aware coverage, import receipt and permitted refresh opportunities | Actual Watch delivery and permission states |
| Learning | Separate stage, baseline and temperature readiness with useful next actions | Real data and reviewed learning gates |
| Wake plan | Canonical warm-up/vibration times, simpler editor, optional app-owned backup | Physical AlarmKit delivery and cancellation; accessories remain separate |
| Bed care | Five independent observations, expiring advice, diagnostic links and recovery guide | Live telemetry and physical maintenance/recovery |

```mermaid
flowchart LR
  Core[Authenticated controller] --> Evidence[Source timestamps and owner scope]
  Evidence --> Tonight[Tonight and wake plan]
  Evidence --> Care[Recording and bed care]
  Local[Private Health history] --> Learning[Recording assistant and learning]
  Confirm[Explicit backup alarm confirmation] --> Alarm[App-owned system alarm]
```

## Validation record — 10 November 2026

- Signed iPhone simulator unit/model plus bed-care run: **1,244 passed, nine existing
  skips**, with no failures. This includes 1,242 unit/model tests and two care UI tests.
- Final iPad care run: **two passed**, including maximum Dynamic Type, diagnostic
  navigation and protection settings. Read-only inspection does not repair hardware.
- Latest signed iPhone offline-report navigation regression: **one passed**.
- Individual prior phone/tablet checks for comfort, Watch, learning, Tonight and wake
  remain documented in their parity records. Build-for-testing and strict lint pass.
- An earlier hosted iPhone offline run failed its Saved reports navigation assertion;
  a hosted iPad recording run failed accessibility-runner initialization. Their
  evidence is retained. The consolidated head must pass the hosted suites before
  merge; local passes do not erase those failures.
- Independent bed-care review accepted the resolved stale-advice, settings-link and
  product-contract findings after complete viewport and large-text recaptures.

These are source and simulator receipts, not TestFlight or physical qualification.
No Pod routine, live adaptation mode, side assignment or Apple Home pairing changed.

## Hosted suite grouping

The first consolidated iPhone run at `579aaa4` reached its 30-minute UI step
limit after six scenarios passed; no assertion failed before timeout. The iPad
runner separately failed to initialize Accessibility before executing tests.
Both failures remain in run 42936859716. The same selectors now run in recording,
guidance and wake groups on both device classes, with the existing 30-minute
per-step guard. `scripts/verify-everyday-ui.sh list <group>` makes the complete
selector inventory reviewable. No scenario or assertion was removed.
