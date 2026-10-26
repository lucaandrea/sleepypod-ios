import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

// Pure Core provenance calculations only: no database, server, sensor or model starts.
const core = resolve(process.argv[2])
const output = resolve(process.argv[3] ?? 'Integration/Fixtures/vital-summary-example.json')
const git = (...args: string[]) => execFileSync('git', ['-C', core, ...args], { encoding: 'utf8' }).trim()
if (git('status', '--porcelain')) throw new Error('Use a clean Core checkout')
const sourceCommit = git('rev-parse', 'HEAD')
const requireCore = createRequire(resolve(core, 'package.json'))
const { summarizeVitalProvenance, summaryProvenanceSchema } = requireCore(resolve(core, 'src/biometrics/profiles/vital-summary-provenance.ts'))
const known = { configurationCount: 1, unknownConfigurationRows: 0, hrvRows: 8, hrvDefinitionCount: 1, unknownHrvRows: 0, singleHrvMetricId: 'hrv_sdnn' }
const inputs = {
  recorded: known,
  mixedConfiguration: { ...known, configurationCount: 2, unknownConfigurationRows: 1 },
  legacy: { ...known, configurationCount: 0, unknownConfigurationRows: 10, hrvDefinitionCount: 0, unknownHrvRows: 8, singleHrvMetricId: null },
  incompatible: { ...known, hrvDefinitionCount: 2 },
  mixedKnownUnknown: { ...known, unknownHrvRows: 1 },
  otherMetric: { ...known, singleHrvMetricId: 'hrv_index' },
  empty: { ...known, hrvRows: 0, hrvDefinitionCount: 0, singleHrvMetricId: null },
}
const cases = Object.fromEntries(Object.entries(inputs).map(([name, value]) => [name, summaryProvenanceSchema.parse(summarizeVitalProvenance(value))]))
if (git('rev-parse', 'HEAD') !== sourceCommit || git('status', '--porcelain')) throw new Error('Core changed during fixture calculation')
writeFileSync(output, JSON.stringify({ synthetic: true, sourceCommit, cases }, null, 2) + '\n')
console.log('Generated seven pure provenance cases from Core; no runtime or device started.')
