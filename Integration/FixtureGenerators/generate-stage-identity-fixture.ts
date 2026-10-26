// Run with Node 24/tsx and --tsconfig pointing to the recorded immutable Core source.
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

async function main() {
  const core = resolve(process.argv[2])
  const load = (path: string) => import(pathToFileURL(resolve(core, path)).href)
  const { stageModelSchema, stageModelBlocks, MAX_STAGE_MODEL_BYTES } = await load('src/lib/personal-stage-model.ts')
  const { DEFAULT_STAGE_RULESET } = await load('src/lib/sleep-stage-rules.ts')
  const { stageNight, stagedBySchema } = await load('src/biometrics/stage-night.ts')
  const { dataHash } = await load('src/biometrics/algorithms/canonical.ts')
  const model = stageModelSchema.parse(JSON.parse(readFileSync('Integration/Fixtures/stage-model-demo.json', 'utf8')))
  const modelHash = dataHash(Object.fromEntries(Object.entries(model).filter(([, value]) => value !== undefined)))
  const start = new Date('2026-10-01T01:00:00Z'); const end = new Date(start.getTime() + 30 * 60000)
  const vitals = Array.from({ length: 30 }, (_, minute) => ({ timestamp: new Date(start.getTime() + minute * 60000),
    heartRate: minute >= 10 && minute < 15 ? 48 : 60 + minute % 3, hrv: 40, breathingRate: 14 }))
  const result = (candidate: unknown, data = vitals) => {
    const computed = stageNight(data, [], 0.8, DEFAULT_STAGE_RULESET, candidate, { start, end })
    return { blocks: stageModelBlocks(computed.epochs), sleepRecordId: 41, stagedBy: stagedBySchema.parse(computed.stagedBy) }
  }
  const fixture = { source: 'Core pure schema and stageNight; synthetic readings, no database or real records',
    maximumBytes: MAX_STAGE_MODEL_BYTES, model, modelHash,
    selection: { model, uploadedAt: start.getTime(), active: true, modelHash },
    library: [{ id: 11, version: model.version, kind: model.kind, uploadedAt: start.getTime(), metrics: model.metrics, selected: true, active: true, modelHash }],
    active: result(model), rules: result(null), noEpochs: result(model, []) }
  writeFileSync(process.argv[3], JSON.stringify(fixture, null, 2) + '\n')
  console.log(JSON.stringify({ maximumBytes: MAX_STAGE_MODEL_BYTES, modelHash, reasons: [fixture.active, fixture.rules, fixture.noEpochs].map(value => value.stagedBy.reason) }))
}
main().catch(error => { console.error(error); process.exitCode = 1 })
