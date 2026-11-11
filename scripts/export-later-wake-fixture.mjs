#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { writeFileSync } from 'node:fs'

// Export real store projections from an isolated database, never from a live Pod.
const core = resolve(process.argv[2] ?? '../sleepypod-core')
const output = resolve(dirname(fileURLToPath(import.meta.url)), '../Integration/Fixtures/later-wake-example.json')
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: core, encoding: 'utf8' }).trim()
const source = `
import { alarmFixture } from './src/alarms/tests/fixture.ts';
const cases = {};
for (const name of ['ordinary', 'movement-window', 'pod-timezone']) {
  const fixture = alarmFixture();
  try {
    fixture.database.exec('UPDATE alarm_schedules SET duration=20,alarm_temperature=105');
    if (name === 'movement-window') fixture.database.exec('UPDATE alarm_schedules SET wake_window=60');
    if (name === 'pod-timezone') fixture.database.exec("UPDATE device_settings SET timezone='America/Los_Angeles'");
    const before = fixture.store.page('left', fixture.now);
    const request = {side:'left', expectedRevision:before.revision, expectedAt:before.alarm.at, time:'09:00'};
    const preview = fixture.store.previewLater(request, fixture.now);
    const saved = {...fixture.store.applyLater(preview, fixture.now), schedulerUpdated:false};
    const restored = fixture.store.write({side:'left', action:'restore', expectedRevision:saved.revision, expectedExpiresAt:saved.change.expiresAt}, fixture.now);
    cases[name] = {before, request, preview, saved, restored};
  } finally { fixture.database.close(); }
}
console.log(JSON.stringify({synthetic:true, sourceCommit:${JSON.stringify(commit)}, now:'2026-10-26T05:00:00.000Z', cases}, null, 2));
`
const data = execFileSync('pnpm', ['exec', 'tsx', '-e', source], { cwd: core, encoding: 'utf8' })
JSON.parse(data)
writeFileSync(output, data)
console.log(`Exported ${output} from ${commit}; scheduler acknowledgment is explicitly false.`)
