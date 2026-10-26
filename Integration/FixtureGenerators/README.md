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
