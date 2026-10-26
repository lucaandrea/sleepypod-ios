import { writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

/** Pure Core schema/hash examples; no database, controller or owner input is accessed. */
async function main() {
  const core = resolve(process.argv[2] ?? '../sleepypod-core')
  const output = resolve(process.argv[3] ?? fileURLToPath(new URL('../Fixtures/experiment-protocols.json', import.meta.url)))
  const { experimentProtocolSchema } = await import(pathToFileURL(join(core, 'src/biometrics/backtest/contracts.ts')).href)
  const { canonicalJson, configHash } = await import(pathToFileURL(join(core, 'src/biometrics/algorithms/canonical.ts')).href)
  const baseline = { version: 'descriptive-evaluation-v1', mode: 'comparison', assumedStageCalibrationQuality: 0, pointToleranceMs: 30000, clockOffsetMs: 0 }
  const uncertainty = { version: 'paired-night-percentile-v1', seed: 'Synthetic 🛏️\n"seed" / \u2028', resamples: 1000, minimumNights: 3 }
  const operational = { maximumWallMs: 10000, maximumPeakRssBytes: 64000000, maximumIngestionAgeMs: 5000 }
  const numeric = { version: 'numeric-objective-v1', qualificationId: 'synthetic-undesignated-policy', metric: 'heart_rate', minimumNights: 3,
    minimumPairedReferencesPerNight: 20, maximumLostObservationFraction: 0.1, minimumMaeImprovement: 0.2,
    maximumNightMaeRegression: 1, maximumRegressedNightFraction: 0.2, maximumSubgroupMaeRegression: 1, requiredSubgroups: [], operational }
  const stage = { version: 'stage-objective-v1', qualificationId: 'synthetic-undesignated-stages', minimumNights: 3,
    minimumPairedDurationMsPerNight: 60000, minimumOutputCoverage: 0.9, maximumLostOutputFraction: 0.1,
    minimumAgreementImprovement: 0.01, maximumNightAgreementRegression: 0.02, maximumRegressedNightFraction: 0.1,
    maximumMacroF1Regression: 0.02, maximumStageF1Regression: 0.02, minimumStageReferenceMsPerNight: 30000, requiredStages: ['wake', 'light'], operational }
  const protocols = [baseline,
    ...[0, 0.1, 0.6, 1, Number.MIN_VALUE, 0.9999999999999999].map(quality => ({ ...baseline, mode: 'stage_replay', assumedStageCalibrationQuality: quality, nightUncertainty: uncertainty })),
    { ...baseline, mode: 'signal_replay', waveformStages: false, pointToleranceMs: 0, clockOffsetMs: -3600000 },
    { ...baseline, mode: 'signal_replay', waveformStages: true, assumedStageCalibrationQuality: 0.3, pointToleranceMs: 300000, clockOffsetMs: 3600000, nightUncertainty: uncertainty },
    { ...baseline, mode: 'signal_replay', waveformStages: true, assumedStageCalibrationQuality: 0.3, objectivePolicy: numeric, stageObjectivePolicy: stage },
    { ...baseline, mode: 'signal_replay', waveformStages: true, assumedStageCalibrationQuality: 0.3, objectivePolicies: [numeric], stageObjectivePolicy: stage },
    { ...baseline, mode: 'signal_replay', objectivePolicies: [numeric, { ...numeric, metric: 'breathing_rate' }, { ...numeric, metric: 'window_ibi_variability_v1' }] },
  ].map(value => experimentProtocolSchema.parse(value))
  const values = [null, false, 'quote" slash/ newline\n\u0001\u2028\u2029😀', { '\ufffd': 1, '😀': 2, 'a': 3 },
    [0, -0, 0.1, -0.1, Number.MIN_VALUE, -Number.MIN_VALUE, Number.MAX_VALUE, Number.MAX_SAFE_INTEGER, 1e-100, 1e100]]
  writeFileSync(output, JSON.stringify({ protocols: protocols.map(protocol => ({ protocol, canonical: canonicalJson(protocol), hash: configHash(protocol) })),
    canonicalVectors: values.map(value => ({ value, canonical: canonicalJson(value), hash: configHash(value) })) }, null, 2) + '\n')
  console.log(`Generated ${protocols.length} Core-validated protocols and ${values.length} canonical vectors.`)
}
main().catch(error => { console.error(error); process.exitCode = 1 })
