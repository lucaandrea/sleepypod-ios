import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { randomUUID } from 'node:crypto'

async function main() {
  const core = resolve(process.argv[2])
  const output = resolve(process.argv[3] ?? 'Integration/Fixtures/control-receipts-example.json')
  if (execFileSync('git', ['status', '--porcelain'], { cwd: core, encoding: 'utf8' }).trim()) throw new Error('Use a clean Core checkout')
  const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: core, encoding: 'utf8' }).trim()
  const requireCore = createRequire(resolve(core, 'package.json'))
  const Database = requireCore('better-sqlite3')
  const { drizzle } = requireCore('drizzle-orm/better-sqlite3')
  const { migrate } = requireCore('drizzle-orm/better-sqlite3/migrator')
  const { ControlService } = requireCore(resolve(core, 'src/controls/service.ts'))
  const { createControlStore } = requireCore(resolve(core, 'src/controls/store.ts'))
  const { beforeControlWrite } = requireCore(resolve(core, 'src/controls/context.ts'))
  const { controlRequestSchema, controlReceiptSchema, controlActionSchema } = requireCore(resolve(core, 'src/controls/contract.ts'))
  process.chdir(core)
  const sqlite = new Database(':memory:')
  try {
    migrate(drizzle(sqlite), { migrationsFolder: resolve(core, 'src/db/migrations') })
    const store = createControlStore(sqlite)
    const instant = 1_793_016_000_000
    const cases: Record<string, unknown> = {}
    for (const name of ['acknowledged', 'unknown', 'not_dispatched', 'rejected', 'expired', 'executing']) {
      const request = controlRequestSchema.parse({ requestId: randomUUID(), issuedAt: instant, expiresAt: instant + 30_000, action: { kind: 'base.stop' } })
      let release: (() => void) | undefined
      const gate = new Promise<void>(resolve => { release = resolve })
      const controller = new ControlService({
        store, runId: `synthetic-${name}`, now: () => name === 'expired' ? request.expiresAt : name === 'rejected' ? instant - 1 : instant,
        monotonicNow: () => 100,
        execute: async () => {
          if (name === 'not_dispatched') return
          beforeControlWrite()
          if (name === 'unknown') throw new Error('Synthetic lost device reply')
          if (name === 'executing') await gate
        },
      })
      const pending = controller.submit(request)
      const receipt = name === 'executing' ? controller.get(request.requestId) : await pending
      cases[name] = { request, receipt: controlReceiptSchema.parse(receipt) }
      release?.(); await pending
    }
    const actions = [
      { kind: 'temperature', side: 'left', temperature: 68, holdMinutes: 30 },
      { kind: 'power', side: 'right', powered: false },
      { kind: 'vibration', side: 'left', intensity: 50, pattern: 'rise', duration: 30 },
      { kind: 'vibration.clear', side: 'right' },
      { kind: 'base.position', head: 30, feet: 15, feedRate: 50 },
      { kind: 'base.stop' },
    ].map(value => controlActionSchema.parse(value))
    mkdirSync(dirname(output), { recursive: true })
    writeFileSync(output, `${JSON.stringify({ synthetic: true, sourceCommit, cases, actions }, null, 2)}\n`)
  } finally { sqlite.close() }
}
main().catch(error => { console.error(error instanceof Error ? error.message : 'Fixture generation failed'); process.exitCode = 1 })
