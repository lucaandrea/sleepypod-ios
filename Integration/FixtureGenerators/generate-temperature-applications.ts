import { createRequire } from 'node:module'
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
async function main() {
 const core=resolve(process.argv[2]), output=resolve(process.argv[3])
 const git=(...args:string[])=>execFileSync('git',['-C',core,...args],{encoding:'utf8'}).trim()
 if(git('status','--porcelain')) throw new Error('Use a clean Core checkout')
 const sourceCommit=git('rev-parse','HEAD'), requireCore=createRequire(resolve(core,'package.json'))
 const {migratedComfortDatabase}=requireCore(resolve(core,'src/comfort/tests/databaseFixture.ts'))
 const {createTemperatureApplicationRecorder,readTemperatureApplications}=requireCore(resolve(core,'src/temperature/applications.ts'))
 process.chdir(core)
 const database=migratedComfortDatabase(':memory:')
 try {
  let now=Date.parse('2026-10-26T08:00:00Z')
  const record=createTemperatureApplicationRecorder(database,()=>now), read=(side='left',beforeId?:number)=>readTemperatureApplications(database,side,beforeId,now)
  const input={side:'left',targetF:68,durationSec:1800,reason:'manual',source:'manual',requestId:'synthetic-owner-hold'}
  const cases:Record<string,unknown>={empty:read()}
  await record(input,async()=>{cases.attempting=read();now+=100})
  cases.acknowledged=read()
  try {await record({...input,reason:'reconcile',source:'autopilot',requestId:'synthetic-policy'},async()=>{now+=100;throw new Error('synthetic unknown')})}catch{}
  cases.unknown=read()
  for(let index=0;index<51;index++) {now+=100;await record({...input,reason:'keepalive',source:null,requestId:null,durationSec:null},async()=>{})}
  cases.firstPage=read();cases.secondPage=read('left',(cases.firstPage as {nextBeforeId:number}).nextBeforeId);cases.otherSide=read('right')
  if(git('rev-parse','HEAD')!==sourceCommit||git('status','--porcelain'))throw new Error('Core changed while generating fixture')
  writeFileSync(output,JSON.stringify({synthetic:true,sourceCommit,cases},null,2)+'\n')
  console.log('Generated seven migrated in-memory application-history cases; no controller or hardware started.')
 }finally{database.close()}
}
main().catch(error=>{console.error(error instanceof Error?error.message:'Fixture failed');process.exitCode=1})
