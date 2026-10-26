# Biometric input examples

`generate-biometric-inputs.ts` regenerates the linked `dataset-demo.json` and `waveform-demo.json` examples through Core's actual reference normalization, session discovery, raw catalog validation and waveform preparation code. It uses a new in-memory SQLite database, six synthetic sessions, synthetic inventory metadata and no RAW files. It never reads owner databases or modifies the Core checkout.

Use Node 24 and an installed Core checkout. From the iOS repository:

```sh
../sleepypod-core/node_modules/.bin/tsx --tsconfig ../sleepypod-core/tsconfig.json \
  Integration/FixtureGenerators/generate-biometric-inputs.ts ../sleepypod-core
```

An optional argument after the Core path chooses a separate output directory. The default writes both bundled fixture files together. Core generates new UUIDs on each run; waveform hashes bind the exact processed parent IDs, so do not regenerate or edit only one file. Run the native dataset and waveform tests after regeneration.

The checked-in examples were prepared against Core's 2026-10-25 contracts. Their hashes describe synthetic snapshots; they do not establish real byte retention, replay qualification, clinical accuracy or physical Pod behavior.

`generate-experiment-protocols.ts` validates twelve protocol examples through Core's strict schema and records their canonical strings and hashes, plus five encoding vectors. It performs no database or controller operations. Run it with the same Node 24/tsx command, substituting that script name; an optional third argument is an output filename. The examples cover explicit stage assumptions, waveform options, uncertainty, old single-policy versus array representations, subnormal numbers and Unicode. Native hashing is used only for in-memory Demo protocols; the live controller remains authoritative for saved hashes and qualification.

`generate-backtest-reports.ts` runs Core's pure evaluator over its generated test readings for comparison, stage replay and waveform replay. It records full retained reports, summary projections, content hashes and every exact stage/numeric/reference trace page, then validates the summary using Core's web view schemas. Run it with the same Node 24/tsx command and an optional output directory. It does not run a RAW worker, read personal records, create activation approval or modify a controller. The three standalone examples intentionally do not become results for requests queued in Demo. A separate `backtest-three-metric-report.json` retains a summary with all 36 subgroup comparisons for native regression coverage. Generation requires Core's bounded multi-metric view fix; these examples were generated against the immutable Core commit `4673112c6c6355452a553b798177f6593bb29abf` (the owner agent owns its integration).


## Temperature presets and Night/Dawn

`generate-temperature-fixture.ts` runs Core's pure curve generator, point simplification and Night/Dawn helpers. `temperature-core.json` records 15 preset cases (three intensities with standard, hardware-limit, warm-only, short-night and daytime inputs), phase grouping, phase shifts and a two-phase template batch. It performs no database, controller or network operations.

The checked-in fixture uses immutable Core commit `cc8d4d0f74102bbfb056000b825b0112ff06f45d`. Extract `src/lib/sleepCurve/{generate,types}.ts`, `src/lib/{scheduleGrouping,scheduleTime,tempColors,tempUtils}.ts`, `src/hardware/types.ts` and `src/components/TempScreen/{nightPhases,tempScreenUtils}.ts` from that revision into a temporary source tree. Supply a tsconfig mapping `@/*` to that tree, then run with Node 24:

```sh
TZ=America/Los_Angeles ../sleepypod-core/node_modules/.bin/tsx --tsconfig "$SNAPSHOT/tsconfig.json" \
  Integration/FixtureGenerators/generate-temperature-fixture.ts "$SNAPSHOT" Integration/Fixtures/temperature-core.json
```

The timezone is explicit because the web's pure grouping helper accepts a browser-local `Date`; native tests apply the corresponding Pod timezone. `ScheduleCurveAlgorithmTests` checks every generated minute, temperature, converted clock and simplified point. `NightPhaseParityTests` checks the literal phase/shift/template payloads and separately verifies native conflict/readback safeguards.
