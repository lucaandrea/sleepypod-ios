import { writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// Generate only migrated in-memory journals; no device, transport or user history.
const core = resolve(process.argv[2] ?? '../sleepypod-core')
const output = resolve(process.argv[3] ?? fileURLToPath(new URL('../Fixtures/night-explanation-example.json', import.meta.url)))
if (execFileSync('git', ['-C', core, 'status', '--porcelain'], { encoding: 'utf8' }).trim()) throw new Error('Use a clean Core checkout for fixture provenance.')
const sourceCommit = execFileSync('git', ['-C', core, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
const requireCore = createRequire(join(core, 'package.json'))
process.chdir(core)
const { nightExplanationExample } = requireCore(join(core, 'src/night/tests/example.ts'))
const now = Date.UTC(2026, 10, 10, 20)
const cases = {
  normal: nightExplanationExample(now),
  right: nightExplanationExample(now, 'right'),
  spring: nightExplanationExample(Date.UTC(2026, 2, 8, 22), 'left', '2026-03-08'),
  autumn: nightExplanationExample(Date.UTC(2026, 10, 1, 22), 'left', '2026-11-01'),
}
if (execFileSync('git', ['-C', core, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() !== sourceCommit
  || execFileSync('git', ['-C', core, 'status', '--porcelain'], { encoding: 'utf8' }).trim()) {
  throw new Error('Core changed during fixture generation.')
}
writeFileSync(output, JSON.stringify({ synthetic: true, sourceCommit, now, cases }, null, 2) + '\n')
console.log('Generated four night examples from Core in-memory journals.')
