# Biometric input examples

`generate-biometric-inputs.ts` regenerates the linked `dataset-demo.json` and `waveform-demo.json` examples through Core's actual reference normalization, session discovery, raw catalog validation and waveform preparation code. It uses a new in-memory SQLite database, six synthetic sessions, synthetic inventory metadata and no RAW files. It never reads owner databases or modifies the Core checkout.

Use Node 24 and an installed Core checkout. From the iOS repository:

```sh
../sleepypod-core/node_modules/.bin/tsx --tsconfig ../sleepypod-core/tsconfig.json \
  Integration/FixtureGenerators/generate-biometric-inputs.ts ../sleepypod-core
```

An optional argument after the Core path chooses a separate output directory. The default writes both bundled fixture files together. Core generates new UUIDs on each run; waveform hashes bind the exact processed parent IDs, so do not regenerate or edit only one file. Run the native dataset and waveform tests after regeneration.

The checked-in examples were prepared against Core's 2026-10-25 contracts. Their hashes describe synthetic snapshots; they do not establish real byte retention, replay qualification, clinical accuracy or physical Pod behavior.
