import { writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Use a fresh migrated in-memory store; no scheduler, transport or owner database starts. */
async function main() {
  const core = resolve(process.argv[2] ?? '../sleepypod-core')
  const output = resolve(process.argv[3] ?? fileURLToPath(new URL('../Fixtures/next-alarm-example.json', import.meta.url)))
  if (execFileSync('git', ['-C', core, 'status', '--porcelain'], { encoding: 'utf8' }).trim()) throw new Error('Use a clean Core checkout for fixture provenance.')
  const sourceCommit = execFileSync('git', ['-C', core, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
  // The test store uses Core's CommonJS cron-parser dependency through tsx's require hook.
  const requireCore = createRequire(join(core, 'package.json'))
  const { alarmFixture, insertAlarm } = requireCore(join(core, 'src/alarms/tests/fixture.ts'))
  const { selectedAlarm } = requireCore(join(core, 'src/alarms/model.ts'))
  process.chdir(core) // Core's test migration reader resolves its checked-in SQL here.
  const fixture = alarmFixture(), {database,store,now}=fixture
  const cases: Record<string, unknown>={}
  const page=()=>store.page('left',now)
  const save=(action:'skip'|'time'|'restore', time?:string)=>{
   const before=page()
   return store.write(action==='restore'?{side:'left',action,expectedRevision:before.revision,expectedExpiresAt:before.change!.expiresAt}
   :{side:'left',action,expectedRevision:before.revision,expectedAt:before.alarm!.at,...(time?{time}:{})},now)
  }
  cases.scheduled=page(); cases.skipped=save('skip'); cases.restored=save('restore'); cases.changed=save('time','08:00')
  cases.expired=store.page('left',Date.parse('2026-10-26T08:17:00Z'))
  database.exec('UPDATE alarm_schedules SET duration=90'); cases.invalidated=page(); save('restore')
  database.exec("UPDATE side_settings SET away_mode=1 WHERE side='left'");cases.away=page()
  database.exec("UPDATE side_settings SET away_mode=0 WHERE side='left'");const second=insertAlarm(database)
  database.prepare('UPDATE alarm_schedules SET vibration_intensity=80 WHERE id=?').run(second);cases.conflicting=page()
  database.prepare('DELETE FROM alarm_schedules WHERE id=?').run(second)
  const occurrence=selectedAlarm(store.context('left'),now)!
  store.claim('left',occurrence,occurrence.at,false);cases.attempting=page()
  store.finish('left',occurrence,'unknown');cases.unknown=page()
  store.finish('left',occurrence,'acknowledged');cases.acknowledged=page()
  database.exec('DELETE FROM alarm_schedules');cases.none=page()
  writeFileSync(output,JSON.stringify({synthetic:true,sourceCommit,now,cases},null,2)+'\n')
  database.close()
  console.log('Generated twelve next-alarm cases from actual migrated Core store; no scheduler or transport started.')
}
main().catch(error => { console.error(error); process.exitCode = 1 })
