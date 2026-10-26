// Run with the Core Node 24/tsx runtime and --tsconfig pointing to an immutable Core checkout.
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { writeFileSync } from 'node:fs'

async function main() {
  const core = resolve(process.argv[2] ?? '../sleepypod-core')
  const load = async (path: string) => import(pathToFileURL(resolve(core, path)).href)
  const { submissionFixture } = await load('src/biometrics/shadow/tests/fixtures/submission.ts')
  const { dataHash, configHash } = await load('src/biometrics/algorithms/canonical.ts')
  const { defaultConfig } = await load('src/biometrics/algorithms/registry-core.ts')
  const { summarizeShadowSnapshot } = await load('src/biometrics/shadow/report-core.ts')
  const { previewReferenceImport } = await load('src/biometrics/references/normalize.ts')
  const { shadowReportSchema } = await load('src/biometrics/shadow/report-contracts.ts')
  const { submitShadowSchema } = await load('src/biometrics/shadow/submission-contracts.ts')
  const { shadowRunDescriptorSchema } = await load('src/biometrics/shadow/descriptors.ts')
  const plan = submissionFixture().plan
  const defaultsHash = configHash(defaultConfig)
  plan.subjectId = 'synthetic-observation-example'
  plan.candidateConfigHash = defaultsHash
  plan.activeConfigHash = defaultsHash
  for (const side of ['left', 'right']) {
    plan.expectedBindings[side].resolvedHash = defaultsHash
    plan.execution.configHashes[side] = defaultsHash
  }
  submitShadowSchema.parse({ plan, idempotencyKey: 'fixture-only' })
  const planHash = dataHash(plan)
  const runId = '60000000-0000-4000-8000-000000000001'
  const attemptId = '60000000-0000-4000-8000-000000000002'
  const samples = Array.from({ length: 9 }, (_, index) => ({ sequence: index, attemptId, side: 'left',
    timestampMs: plan.startMs + index * 1000, inputHash: null, candidateConfigHash: defaultsHash, activeConfigHash: defaultsHash,
    readings: [{ metric: 'heart_rate', active: { value: 60 + index % 3, quality: 1 }, candidate: { value: index % 4 === 3 ? null : 59 + index % 3, quality: 1 } }] }))
  const input = { side: 'left', subjectId: plan.subjectId, source: 'Synthetic example reference', timePolicy: { disambiguation: 'reject' },
    rows: samples.map((sample: any, index: number) => ({ recordKey: `synthetic-${index}`, metric: 'heart_rate', value: 60 + index % 3, unit: 'bpm', timestampMs: sample.timestampMs })) }
  const reference = previewReferenceImport(input)
  const run = shadowRunDescriptorSchema.parse({ id: runId, side: 'left', subjectId: plan.subjectId, state: 'completed', planHash,
    candidateConfigHash: defaultsHash, activeConfigHash: defaultsHash, candidateRevisionId: null, candidateIdentitySaved: true,
    startMs: plan.startMs, endMs: plan.endMs, createdAtMs: plan.startMs - 1000, endedAtMs: plan.endMs,
    heartbeatAtMs: plan.endMs, reason: 'precomputed_synthetic_example', pointCount: samples.length,
    byteCount: Buffer.byteLength(JSON.stringify(samples)), workerReceiptAvailable: false })
  const snapshot = { samples, capturedAtMs: plan.endMs, snapshotHash: dataHash({ synthetic: true, samples, run }),
    run: { id: runId, plan, plan_hash: planHash, state: 'completed', reason: run.reason, heartbeat_at_ms: run.heartbeatAtMs, lease_until_ms: null, workerReceipt: null } }
  const summarize = (reference: any) => {
    const report = summarizeShadowSnapshot(snapshot, reference, dataHash(plan.execution))
    report.health = 'issues_detected'
    report.issues.unshift('simulated_demo')
    report.limitations.push('Precomputed synthetic example. No hardware, worker execution, or qualified activation evidence.')
    return shadowReportSchema.parse({ ...report, reportHash: dataHash(report) })
  }
  const result = { generatedFrom: 'Core pure observation report evaluator', run, prepared: { status: 'prepared_not_admitted', plan, planHash }, reference: input,
    report: summarize(null), comparison: summarize(reference) }
  const destination = process.argv[3] ?? 'Integration/Fixtures/biometric-observation-example.json'
  writeFileSync(destination, JSON.stringify(result, null, 2) + '\n')
  console.log(JSON.stringify({ destination, reportHash: result.report.reportHash, comparisonHash: result.comparison.reportHash, observations: samples.length }))
}
main().catch(error => { console.error(error); process.exitCode = 1 })
