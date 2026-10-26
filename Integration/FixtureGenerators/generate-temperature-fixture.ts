// Run with Node 24/tsx against the recorded Core source tree and its @/* tsconfig alias.
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
async function main() {
const directory = resolve(process.argv[2])
const source = (name: string) => pathToFileURL(resolve(directory, 'src', name)).href
const { generateSleepCurve, curveToScheduleTemperatures } = await import(source('lib/sleepCurve/generate.ts'))
const { nightPhases, phaseShiftUpdates, templateRows, templateBatch } = await import(source('components/TempScreen/nightPhases.ts'))
const { simplifySetPoints } = await import(source('lib/scheduleGrouping.ts'))
const examples = []
for (const intensity of ['cool','balanced','warm'] as const) {
 for (const [bedtimeMinutes,wakeMinutes,minTempF,maxTempF] of [[1320,420,68,86],[1320,420,55,110],[1320,420,85,95],[1320,1365,68,86],[360,720,70,82]]) {
  const input={intensity,bedtimeMinutes,wakeMinutes,minTempF,maxTempF}
  const temperatures = curveToScheduleTemperatures(generateSleepCurve(input),bedtimeMinutes)
  examples.push({input,points:generateSleepCurve(input),temperatures,simplified:simplifySetPoints(Object.entries(temperatures).map(([time,temperature])=>({time,temperature:Math.round(Math.max(55,Math.min(110,temperature)))})))})
 }
}
let identifier=0
const temperatures=['saturday','sunday','monday'].flatMap(dayOfWeek=>[{time:'22:00',temperature:74},{time:'01:00',temperature:68},{time:'06:00',temperature:82}].map(row=>({...row,id:++identifier,dayOfWeek,enabled:true})))
const power=[{id:20,dayOfWeek:'saturday',endAction:'turn_off'},{id:21,dayOfWeek:'sunday',endAction:'turn_off'},{id:22,dayOfWeek:'monday',endAction:'maintain'}]
const now=new Date('2026-10-25T09:00:00Z')
const phases=nightPhases(temperatures as any,now,power as any)!
const templates=templateRows(temperatures as any)
const draft=nightPhases(templates,new Date('2026-10-28T04:00:00Z'))!
writeFileSync(process.argv[3], JSON.stringify({synthetic:true,source:'cc8d4d0f74102bbfb056000b825b0112ff06f45d',timezone:'America/Los_Angeles',examples,night:{now:now.toISOString(),temperatures,power,phases,updates:phaseShiftUpdates(temperatures as any,phases,'night',3)},template:{rows:templates,phases:draft,batch:templateBatch('left',{temperature:temperatures,power} as any,templates,draft,{night:75,dawn:80},'maintain')}},null,2))
}
main().catch(error => { console.error(error); process.exitCode = 1 })
