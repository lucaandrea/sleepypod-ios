import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

async function main() {
  const core = resolve(process.argv[2]), output = resolve(process.argv[3])
  const git = (...args: string[]) => execFileSync('git', ['-C', core, ...args], { encoding: 'utf8' }).trim()
  if (git('status', '--porcelain')) throw new Error('Use a clean Core checkout')
  const sourceCommit = git('rev-parse', 'HEAD'), temporary = mkdtempSync(join(tmpdir(), 'native-comfort-owner-'))
  // Reuse Core's isolated database fixture; replace only its spy with a no-op and make imports absolute.
  const source = readFileSync(resolve(core, 'src/comfort/tests/ownerFixture.ts'), 'utf8')
    .replace("import { vi } from 'vitest'\n", '').replace('vi.fn()', '() => {}')
    .replace(/from '@\/([^']+)'/g, (_match, path) => `from '${resolve(core, path)}'`)
    .replace(/from '(\.\.?\/[^']+)'/g, (_match, path) => `from '${resolve(core, 'src/comfort/tests', path)}'`)
  const fixturePath = join(temporary, 'fixture.ts')
  writeFileSync(fixturePath, source)
  const requireCore = createRequire(resolve(core, 'package.json'))
  process.chdir(core)
  const { ownerFixture } = requireCore(fixturePath)
  const fixture = ownerFixture()
  try {
    const statuses: Record<string, unknown> = { initial: await fixture.owner.status('left'), right: await fixture.owner.status('right') }
    const reviews: Record<string, unknown> = { qualification: await fixture.owner.prepare({ side: 'left', purpose: 'qualification', kind: 'presence_empty' }) }
    const prepare = fixture.owner.prepare
    fixture.owner.prepare = async (input: { side: string, purpose: string, kind: string | null }) => {
      const review = await prepare(input)
      if (input.kind) reviews[input.kind] = review
      return review
    }
    await fixture.ready()
    statuses.ready = await fixture.owner.status('left')
    reviews.activation = await fixture.owner.prepare({ side: 'left', purpose: 'activation', kind: null })
    await fixture.owner.confirm({ side: 'left', id: (reviews.activation as { id: string }).id, confirmed: true, note: 'Synthetic fixture only; no physical night or owner grant.' })
    statuses.active = await fixture.owner.status('left')
    const first = (statuses.active as { qualifications: { kind: string, id: string }[] }).qualifications[0]
    await fixture.owner.retest('left', first.kind, first.id)
    statuses.retest = await fixture.owner.status('left')
    const application = { requestId: '765b1922-5c71-4a53-a138-1e013ca1f38a', segment: 'synthetic-night:first', targetF: 74, previousF: 75,
      createdAt: fixture.now() - 2000, reservedAt: fixture.now() - 1000, finishedAt: fixture.now(), outcome: 'unknown', receiptId: null }
    fixture.configure({ application })
    statuses.uncertain = await fixture.owner.status('left')
    reviews.resolution = await fixture.owner.prepare({ side: 'left', purpose: 'resolution', kind: null })
    await fixture.owner.confirm({ side: 'left', id: (reviews.resolution as { id: string }).id, confirmed: true, note: 'Synthetic recovery; no command replay.' })
    statuses.resolved = await fixture.owner.status('left')
    if (git('rev-parse', 'HEAD') !== sourceCommit || git('status', '--porcelain')) throw new Error('Core changed during fixture generation')
    writeFileSync(output, JSON.stringify({ synthetic: true, sourceCommit, statuses, reviews }, null, 2) + '\n')
    console.log('Generated isolated owner qualification, activation, retest and recovery records. No controller or hardware started.')
  } finally { fixture.database.close(); rmSync(temporary, { recursive: true, force: true }) }
}
main().catch(error => { console.error(error instanceof Error ? error.message : 'Fixture failed'); process.exitCode = 1 })
