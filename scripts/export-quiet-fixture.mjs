#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { writeFileSync } from 'node:fs'

const core = resolve(process.argv[2] ?? '../sleepypod-core')
const output = resolve(dirname(fileURLToPath(import.meta.url)), '../Integration/Fixtures/personal-quiet-v1.json')
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: core, encoding: 'utf8' }).trim()
// Exercise the real API projection on an isolated, migrated in-memory database.
const source = `
import { randomBytes, randomUUID } from 'node:crypto';
import { migratedComfortDatabase } from './src/comfort/tests/databaseFixture.ts';
import { HouseholdStore } from './src/household/store.ts';
import { HouseholdQuietStore } from './src/household/quiet.ts';
import { HouseholdQuietApi } from './src/household/quietApi.ts';
(async () => {
 const database = migratedComfortDatabase();
 try {
  const now = Date.parse('2026-11-12T07:00:00Z');
  const identities = new HouseholdStore(database, () => now);
  const secret = () => randomBytes(32).toString('base64url');
  const owner = secret(), member = secret();
  const context = () => ({requestId:randomUUID(),expectedSessionRevision:1,expectedAssignmentRevision:1});
  identities.setup({requestId:randomUUID(),displayName:'Example owner',deviceName:'Phone',deviceSecret:owner,
    currentMode:'solo-anywhere',sourceSide:'left',acknowledgeExistingOwner:true});
  const invitation = identities.createInvitation(owner,{...context(),kind:'new_person',invitation:secret(),expiresInMinutes:30});
  identities.join({invitation:invitation.invitation,displayName:'Example partner',deviceName:'Tablet',deviceSecret:member});
  const quiet = new HouseholdQuietStore(database,identities,() => now);
  const api = new HouseholdQuietApi({identities,quiet,now:() => now});
  const call = async (credential,path='me/quiet',body=undefined) => {
    const request = new Request('https://quiet-fixture.invalid/api/v1/'+path,{method:body?'POST':'GET',headers:{authorization:'Bearer '+credential}});
    return await api.response(request,credential,body,() => {}).json();
  };
  const write = {...context(),expectedRevision:null,issuedAt:now,expiresAt:now+30000,until:now+3600000};
  const idle=await call(owner), saved=await call(owner,'me/quiet',write);
  await call(member,'me/quiet',{...context(),expectedRevision:null,issuedAt:now,expiresAt:now+30000,until:now+7200000});
  const shared=await call(owner);
  const clear={...context(),expectedRevision:saved.receipt.revision,issuedAt:now,expiresAt:now+30000,until:null};
  const cleared=await call(owner,'me/quiet',clear), partner=await call(owner);
  const missing=await call(owner,'me/quiet/requests/'+randomUUID());
  console.log(JSON.stringify({synthetic:true,sourceCommit:${JSON.stringify(commit)},session:api.present(identities.session(owner)),
    memberSession:api.present(identities.session(member)),idle,write,saved,shared,clear,cleared,partner,missing},null,2));
 } finally { database.close(); }
})().catch(error => {console.error(error);process.exitCode=1});
`
const data = execFileSync('pnpm', ['exec', 'tsx', '-e', source], { cwd: core, encoding: 'utf8' })
JSON.parse(data)
writeFileSync(output, data)
console.log(`Exported personal quiet API fixtures from ${commit}. No live controller was contacted.`)
