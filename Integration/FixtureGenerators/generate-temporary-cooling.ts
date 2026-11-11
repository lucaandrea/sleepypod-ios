import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

/** Replay the actual Core authority against isolated memory; never start a transport. */
async function main() {
  const core = resolve(process.argv[2]), output = resolve(process.argv[3])
  const git = (...args: string[]) => execFileSync('git', ['-C', core, ...args], { encoding: 'utf8' }).trim()
  if (git('status', '--porcelain')) throw new Error('Use a clean Core checkout')
  const sourceCommit = git('rev-parse', 'HEAD'), requireCore = createRequire(resolve(core, 'package.json'))
  const { TemperatureController } = requireCore(resolve(core, 'src/temperature/controller.ts'))
  const { createCoolingStore } = requireCore(resolve(core, 'src/temperature/coolingStore.ts'))
  const { migratedComfortDatabase } = requireCore(resolve(core, 'src/comfort/tests/databaseFixture.ts'))
  process.chdir(core)
  const database = migratedComfortDatabase(':memory:')
  try {
    let now = 1_794_350_000_000, target = 70, deadline: number | null = null
    const storage = createCoolingStore(database), scope = 'a'.repeat(64)
    let context = { scope, observedAt: now, available: true, readyToStart: true, sessionEndsAt: now + 28_800_000,
      wakeStartsAt: null, reason: 'Synthetic fixture; no Pod connected.' }
    const controller = new TemperatureController({ now: () => now,
      withSideLock: async (_side: string, callback: () => Promise<unknown>) => callback(),
      cooling: { ...storage, context: () => context },
      readHold: () => null, writeHold: () => {}, readBaseline: () => [], isPowered: () => true,
      readCurrentTarget: () => target, readHardwareDeadline: () => deadline,
      writeHardwareDeadline: (_side: string, value: number | null) => { deadline = value },
      isBlocked: () => false, connect: async () => {},
      apply: async (_side: string, value: number) => { target = value }, powerOff: async () => {}, publish: () => {},
    })
    const cases: Record<string, unknown> = { ready: controller.coolingStatus('left') }
    const identifier = '00000000-0000-4000-8000-000000000022'
    cases.active = await controller.startCooling('left', identifier, scope, 70, now + 1_200_000)
    now += 31_000
    cases.waiting = controller.coolingStatus('left')
    const lease = storage.read('left')
    storage.write('left', { ...lease, phase: 'unknown' })
    cases.unknown = controller.coolingStatus('left')
    context = { ...context, observedAt: now }
    cases.cancelled = await controller.cancelCooling('left', identifier)
    context = { ...context, available: false }
    cases.unavailable = controller.coolingStatus('right')
    if (git('rev-parse', 'HEAD') !== sourceCommit || git('status', '--porcelain')) throw new Error('Core changed during fixture generation')
    writeFileSync(output, JSON.stringify({ synthetic: true, sourceCommit, cases }, null, 2) + '\n')
    console.log('Generated six temporary-cooling states from the Core authority with no hardware transport.')
  } finally { database.close() }
}
main().catch(error => { console.error(error instanceof Error ? error.message : 'Fixture failed'); process.exitCode = 1 })
