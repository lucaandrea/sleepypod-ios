import { writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// Evaluate synthetic observations through the exact Core projection; no live database or transport.
const core = resolve(process.argv[2] ?? '../sleepypod-core')
const output = resolve(process.argv[3] ?? fileURLToPath(new URL('../Fixtures/bed-care-example.json', import.meta.url)))
if (execFileSync('git', ['-C', core, 'status', '--porcelain'], { encoding: 'utf8' }).trim()) throw new Error('Use a clean Core checkout for fixture provenance.')
const sourceCommit = execFileSync('git', ['-C', core, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
const requireCore = createRequire(join(core, 'package.json'))
const { evaluateBedCare } = requireCore(join(core, 'src/bed-care/evaluate.ts'))
const { evaluateRecordingHealth } = requireCore(join(core, 'src/recording-health/evaluate.ts'))
const now = Date.UTC(2026, 10, 10, 20)
const recording = evaluateRecordingHealth({ now, path: null, history: null, recordingDatabaseReadable: true,
  storage: { availableBytes: 512 * 1024 * 1024, totalBytes: 4 * 1024 * 1024 * 1024 } })
const normal = { now, hardware: { at: now - 5000, water: 'ok', priming: false }, blockedSides: [], protectionEnabled: true, recording, lastExportAt: now - 86400000 + 0.25 }
const cases = {
  observed: evaluateBedCare(normal),
  attention: evaluateBedCare({ ...normal, hardware: { ...normal.hardware, water: 'low' }, blockedSides: ['left'] }),
  priming: evaluateBedCare({ ...normal, hardware: { ...normal.hardware, priming: true } }),
  unknown: evaluateBedCare({ now, hardware: null, blockedSides: null, protectionEnabled: null, recording: null, lastExportAt: null }),
  protectionDisabled: evaluateBedCare({ ...normal, protectionEnabled: false }),
  protectionUnknown: evaluateBedCare({ ...normal, protectionEnabled: null }),
  expired: evaluateBedCare({ ...normal, now: now - 60000 }),
}
writeFileSync(output, JSON.stringify({ synthetic: true, sourceCommit, now, cases }, null, 2) + '\n')
console.log('Generated seven care cases from Core using only synthetic observations.')
