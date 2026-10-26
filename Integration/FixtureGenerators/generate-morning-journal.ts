import { writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

/** Generate synthetic check-ins through Core's schema and pure pattern calculation. */
async function main() {
  const core = resolve(process.argv[2] ?? '../sleepypod-core')
  const output = resolve(process.argv[3] ?? fileURLToPath(new URL('../Fixtures/morning-journal-example.json', import.meta.url)))
  if (execFileSync('git', ['-C', core, 'status', '--porcelain'], { encoding: 'utf8' }).trim()) throw new Error('Use a clean Core checkout for fixture provenance.')
  const sourceCommit = execFileSync('git', ['-C', core, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
  const { journalPageSchema } = await import(pathToFileURL(join(core, 'src/journal/contract.ts')).href)
  const { journalPatterns } = await import(pathToFileURL(join(core, 'src/journal/patterns.ts')).href)
  const today = '2026-10-25', timeZone = 'America/Los_Angeles'
  const entries = Array.from({ length: 14 }, (_, index) => {
    const date = `2026-10-${String(25 - index).padStart(2, '0')}`
    return {
      side: 'left' as const, date, revision: `10000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`,
      record: { side: 'left' as const, date, fields: { restfulness: 3 + index % 3, comfort: index % 3 === 0 ? 'warm' as const : 'comfortable' as const,
        caffeine: index % 2 === 0, alcohol: false, exercise: index % 2 === 1, notes: index === 0 ? 'Synthetic check-in for native interface testing.' : '' },
        timeZone, origin: index < 7 ? 'sleepypod' as const : 'free-sleep' as const,
        createdAt: index < 7 ? Date.parse(date + 'T15:00:00Z') : null, updatedAt: index < 7 ? Date.parse(date + 'T15:00:00Z') : null,
        importedAt: index < 7 ? null : Date.parse(today + 'T16:00:00Z') }
    }
  })
  const sources = ['sleepypod', 'free-sleep'].map((source, sourceIndex) => ({ source: source as 'sleepypod'|'free-sleep', presence: {
    status: 'ready' as const, timeZone, minutes: new Map(entries.map((entry, index) => [entry.date, 440 + (index % 2 ? 25 : -15) + sourceIndex * 20]))
  } }))
  const page = journalPageSchema.parse({ apiVersion: 1, side: 'left', timeZone, deviceDate: today, from: '2026-09-26', through: today,
   selected: entries[0], entries, patterns: journalPatterns(entries, sources) })
  writeFileSync(output, JSON.stringify({ synthetic: true, sourceCommit, page }, null, 2) + '\n')
}
main().catch(error => { console.error(error); process.exitCode = 1 })
