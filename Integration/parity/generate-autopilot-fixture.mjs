// node Integration/parity/generate-autopilot-fixture.mjs /path/to/sleepypod-core
// Runs Core's pure replay with synthetic history. The live DAC module is excluded.
import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { writeFileSync } from 'node:fs'
const coreRoot = resolve(process.argv[2])
const requireCore = createRequire(resolve(coreRoot, 'package.json'))
const { build } = requireCore('esbuild')
const source = `
import { runBacktest } from './src/automation/backtest.ts'
const startMs = Date.parse('2026-10-25T04:00:00Z')
const endMs = startMs + 6 * 3600000
const series = Array.from({length: 181}, (_, index) => ({t: startMs + index * 120000, v: 72 + 8 * Math.sin(index / 18)})).filter((_, index) => index < 65 || index > 90)
const rule = {side:'left',cooldownMin:null,trigger:{kind:'tick',everyMin:1},conditions:{kind:'timeBetween',start:'21:00',end:'07:00'},actions:[{kind:'setTemperature',temp:{kind:'binary',op:'+',left:{kind:'signal',signal:'ambient.temperature'},right:{kind:'literal',value:2}},clamp:{min:68,max:78},mode:'policy'}]}
export default {ok:true,message:'Chart validation fixture · synthetic room readings processed by Core. This is not a replay of the edited rule or a real night.',night:{label:'Synthetic night',date:'2026-10-24'},result:runBacktest({rule,timezone:'America/Los_Angeles',startMs,endMs,stepMin:2,series:{'ambient.temperature':series}})}
`
const built = await build({stdin:{contents:source,resolveDir:coreRoot,loader:'ts'},bundle:true,platform:'node',format:'esm',write:false,tsconfig:resolve(coreRoot,'tsconfig.json'),plugins:[{
  name:'exclude-live-dac',setup(builder){
    builder.onResolve({filter:/hardware\/dacMonitor\.instance$/},()=>({path:'dac-disabled',namespace:'fixture'}))
    builder.onLoad({filter:/.*/,namespace:'fixture'},()=>({contents:'export const getDacMonitorIfRunning = () => null',loader:'js'}))
  }
}]})
const fixture = (await import('data:text/javascript;base64,' + Buffer.from(built.outputFiles[0].text).toString('base64'))).default
writeFileSync(new URL('../../Sleepypod/Resources/automation-backtest-fixture.json',import.meta.url),JSON.stringify(fixture,null,2)+'\n')
console.log(JSON.stringify({points:fixture.result.setpoint.length,summary:fixture.result.summary}))
