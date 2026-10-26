import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

/** Generate synthetic report examples through Core's pure evaluator, never a controller or RAW worker. */
async function main() {
  const coreDirectory = resolve(process.argv[2] ?? '../sleepypod-core')
  const outputDirectory = resolve(process.argv[3] ?? fileURLToPath(new URL('../Fixtures/', import.meta.url)))
  const importCore = (path: string) => import(pathToFileURL(join(coreDirectory, path)).href)
  const { backtestFixture } = await importCore('src/biometrics/backtest/tests/fixtures/backtest.ts')
  const { waveformBacktestFixture, candidateConfig } = await importCore('src/biometrics/backtest/tests/fixtures/waveform.ts')
  const { evaluateBacktest } = await importCore('src/biometrics/backtest/evaluator.ts')
  const { configHash, dataHash } = await importCore('src/biometrics/algorithms/canonical.ts')
  const { summarizeBacktestResult } = await importCore('src/biometrics/backtest/report-summary.ts')
  const { pageStageTraces } = await importCore('src/biometrics/backtest/trace-page.ts')
  const { pageNumericTraces } = await importCore('src/biometrics/backtest/numeric-trace-page.ts')
  const { pageReferenceTraces } = await importCore('src/biometrics/backtest/reference-trace-page.ts')
  const views = await importCore('src/components/biometrics/Calibration/report-view.ts')
  const samples = []
  let multiMetric
  for (const [index, name] of ['comparison', 'stage_replay', 'signal_replay', 'signal_replay_three_metrics'].entries()) {
    const mode = name === 'signal_replay_three_metrics' ? 'signal_replay' : name
    const work = mode === 'signal_replay' ? waveformBacktestFixture({ candidate: true, stages: true, objective: true }) : backtestFixture()
    work.job.protocol.mode = mode
    if (name === 'signal_replay_three_metrics') {
      work.job.protocol.objectivePolicies = ['heart_rate', 'breathing_rate', 'window_ibi_variability_v1'].map(metric => ({ ...work.job.protocol.objectivePolicies[0], metric }))
    }
    if (mode !== 'signal_replay') {
      const candidate = candidateConfig()
      work.job.configs.push({ ...work.job.configs[0], label: 'candidate', resolved: candidate, resolvedHash: configHash(candidate) })
    }
    const candidateId = `00000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`
    work.job.configs.find((configuration: any) => configuration.label === 'candidate').revisionId = candidateId
    work.job.protocolHash = configHash(work.job.protocol)
    const report = evaluateBacktest(work)
    report.limitations.unshift('Synthetic example scored by Core from generated fixture readings. No personal records, RAW processing, live health measurements or validated improvement.')
    const id = `00000000-0000-4000-9000-${String(index + 1).padStart(12, '0')}`
    const completedAtMs = Date.parse('2026-10-26T07:00:00Z') + index
    const result = { jobId: id, fencingToken: 1, report, contentHash: dataHash(report), completedAtMs, releasedAtMs: null, available: true, currentHoldoutUseCount: 0 }
    const summary = summarizeBacktestResult(result)
    views.reportViewSchema.parse(summary.report)
    views.numericReportViewSchema.parse(summary.report)
    if (mode !== 'comparison') views.stageReportViewSchema.parse(summary.report)
    const stages = [], numeric = [], references = []
    for (const configuration of ['default', 'current', 'candidate']) {
      const input = { id, expectedContentHash: result.contentHash, configuration, cohortId: 'night', offset: 0, limit: 3 }
      if (mode !== 'comparison') {
        let page = pageStageTraces(report, input)
        stages.push(page)
        while (page.nextCursor) { page = pageStageTraces(report, { ...input, offset: page.nextCursor.offset }); stages.push(page) }
      }
      if (mode === 'signal_replay') {
        let page = pageNumericTraces(report, input)
        numeric.push(page)
        while (page.nextCursor) { page = pageNumericTraces(report, { ...input, offset: page.nextCursor.offset }); numeric.push(page) }
      }
    }
    for (const metric of ['heart_rate', 'breathing_rate', 'window_ibi_variability_v1', 'sleep_stages']) {
      const retained = { contentHash: work.job.datasetHash, snapshot: work.dataset.snapshot }
      const input = { id, expectedContentHash: result.contentHash, cohortId: 'night', metric, offset: 0, limit: 3 }
      let page = pageReferenceTraces(report, retained, input)
      references.push(page)
      while (page.nextCursor) { page = pageReferenceTraces(report, retained, { ...input, offset: page.nextCursor.offset }); references.push(page) }
    }
    const job = { id, experimentId: work.job.experimentId, datasetId: work.job.datasetId, datasetHash: work.job.datasetHash,
      evaluatorBuildHash: work.job.evaluatorBuildHash, split: work.job.split, state: 'succeeded', attempt: 1,
      progress: { phase: 'synthetic_example_complete', completedNights: report.nights.length, totalNights: report.nights.length },
      cancellationRequestedAtMs: null, error: null, createdAtMs: completedAtMs - 1000, updatedAtMs: completedAtMs,
      configurations: work.job.configs.map((configuration: any) => ({ label: configuration.label, revisionId: configuration.revisionId, hash: configuration.resolvedHash })),
      evaluationScope: mode === 'comparison' ? 'original_readings_comparison' : mode === 'stage_replay' ? 'stage_rules_on_original_readings' : 'retained_waveform_replay' }
    const example = { name, job, summary, report, stagePages: stages, numericPages: numeric, referencePages: references }
    if (name === 'signal_replay_three_metrics') multiMetric = { job, summary }
    else samples.push(example)
  }
  mkdirSync(outputDirectory, { recursive: true })
  writeFileSync(join(outputDirectory, 'backtest-reports-demo.json'), JSON.stringify(samples, null, 2) + '\n')
  writeFileSync(join(outputDirectory, 'backtest-three-metric-report.json'), JSON.stringify(multiMetric, null, 2) + '\n')
  console.log('Generated three Demo reports plus a three-metric regression report with exact trace pages; no hardware, personal data or RAW worker used.')
}
main().catch(error => { console.error(error); process.exitCode = 1 })
