#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { readFileSync, writeFileSync } from 'node:fs'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const core = resolve(process.argv[2] ?? '../sleepypod-core')
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: core, encoding: 'utf8' }).trim()
const session = JSON.parse(readFileSync(resolve(root, 'Integration/Fixtures/personal-quiet-v1.json'), 'utf8')).session
session.capabilities.comfortExperiments = true
session.capabilities.comfortExperimentExecution = true
const source = `
import {randomUUID} from 'node:crypto';
import {migratedComfortDatabase} from './src/comfort/tests/databaseFixture.ts';
import {ComfortExperimentService} from './src/comfort/experiments/service.ts';
import {experimentResponse} from './src/comfort/experiments/http.ts';
import {experimentLibrarySchema,experimentReviewSchema,experimentDetailSchema} from './src/comfort/experiments/browserContract.ts';
import {experimentExecutionStatusSchema} from './src/comfort/experiments/execution-contract.ts';
import {context,fixtureSchedule,createdAt} from './src/comfort/experiments/tests/fixture.ts';
const session=${JSON.stringify(session)};
(async()=>{
 const cases={};
 for(const kind of ['legacy','personal']) {
  const database=migratedComfortDatabase();
  try {
   let now=createdAt;
   const scope=kind==='legacy'?{kind,installationId:randomUUID()}:{kind,podId:session.podId,householdId:session.householdId,accountId:session.accountId,sleeperId:session.selfSleeperId,sessionRevision:session.sessionRevision,householdRevision:session.householdRevision,assignmentRevision:session.assignmentRevision};
   const access={subjectKey:context.subjectKey,scope,binding:{fixture:true},routineSide:'left',ready:true};
   const availability={context,schedule:fixtureSchedule(),reason:'Synthetic comparison within the saved overnight range.'};
   const service=new ComfortExperimentService(database,()=>now,()=>availability);
   const call=async(path='',body=undefined)=>await experimentResponse(new Request('https://experiment-fixture.invalid/api/v1/comfort/experiments/'+path,{method:body?'POST':'GET'}),body,service,()=>access,()=>now).json();
   const proposal={firstNightDate:'2026-11-13',variantF:69};
   const library=experimentLibrarySchema.parse(await call());
   const review=experimentReviewSchema.parse(await call('preview',proposal));
   const saved=experimentDetailSchema.parse(await call('confirm',{reviewId:review.reviewId,planHash:review.planHash}));
   const savedLibrary=experimentLibrarySchema.parse(await call());
   const id=saved.record.plan.id, controlId=randomUUID();
   const status={version:1,generatedAt:now,scope,planId:id,planStatus:'planned',controllerRunning:true,state:'not_admitted',review:null,admission:null,applications:[]};
   const controlReview={...status,review:{id:controlId,planHash:review.planHash,createdAt:now,expiresAt:now+60000,sides:['left','right']}};
   const admitted={...status,state:'admitted',admission:{id:controlId,admittedAt:now,endsAt:review.schedule.windows.at(-1).windowEnd,revokedAt:null,reason:null,sides:['left','right']}};
   now=review.schedule.windows[0].windowStart+1000;
   const running=experimentDetailSchema.parse(await call(id));
   const uncertain={...admitted,generatedAt:now,applications:[{id:randomUUID(),side:'left',requestedTargetF:review.nights[0].targetF,attemptedAt:now-500,outcome:'unknown',acknowledgment:'unconfirmed',finishedAt:now-250,resolution:null}]};
   const recovered={...uncertain,state:'revoked',admission:{...admitted.admission,revokedAt:now,reason:'Fresh target readback after an uncertain attempt'},applications:uncertain.applications.map(item=>({...item,outcome:'resolved',resolution:{observedAt:now-100,resolvedAt:now,targetF:70}}))};
   now=review.schedule.windows[0].windowEnd+1000;
   const feedback={nightDate:review.nights[0].date,confirmedFullNight:true,comfort:8,unwantedAdjustments:1,problem:false};
   const feedbackSaved=experimentDetailSchema.parse(await call(id+'/feedback',{expectedRevision:saved.record.revision,feedback}));
   const stopped=experimentDetailSchema.parse(await call(id+'/stop',{expectedRevision:feedbackSaved.record.revision}));
   const closedControl={...admitted,generatedAt:now,planStatus:'stopped'};
   const cancelled={...closedControl,state:'revoked',admission:{...admitted.admission,revokedAt:now,reason:'Cancelled by the sleeper'}};
   for(const value of [status,controlReview,admitted,uncertain,recovered,closedControl,cancelled])experimentExecutionStatusSchema.parse(value);
   cases[kind]={proposal,library,review,saved,savedLibrary,status,controlReview,admitted,running,uncertain,recovered,feedback,feedbackSaved,stopped,closedControl,cancelled};
  }finally{database.close()}
 }
 console.log(JSON.stringify({synthetic:true,sourceCommit:${JSON.stringify(commit)},executionEvidence:'Synthetic schema-checked receipts; no firmware or qualification was exercised.',session,cases},null,2));
})().catch(error=>{console.error(error);process.exitCode=1});
`
const data = execFileSync('pnpm', ['exec', 'tsx', '-e', source], { cwd: core, encoding: 'utf8' })
JSON.parse(data)
writeFileSync(resolve(root, 'Integration/Fixtures/comfort-experiments-v1.json'), data)
console.log(`Exported isolated controller planning fixtures and synthetic execution receipts from ${commit}. No live controller contacted.`)
