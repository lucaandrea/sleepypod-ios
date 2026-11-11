import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// Load only synthetic examples and pure contracts; no Pod, database or account is opened.
const core = resolve(process.argv[2] ?? '../sleepypod-core')
const output = resolve(process.argv[3] ?? fileURLToPath(new URL('../Fixtures/personal-learning-v1.json', import.meta.url)))
if (execFileSync('git', ['-C', core, 'status', '--porcelain', '--untracked-files=no'], { encoding: 'utf8' }).trim())
  throw new Error('Use a tracked-clean Core checkout for fixture provenance.')
const sourceRevision = execFileSync('git', ['-C', core, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
const requireCore = createRequire(join(core, 'package.json'))
const preparation = requireCore(join(core, 'src/household/fixtures/preparation-v1.json'))
const { householdSessionSchema } = requireCore(join(core, 'src/household/contract.ts'))
const { learningFixture } = requireCore(join(core, 'src/household/web/tests/learningFixture.ts'))
const { learningArchivePageSchema, learningRecordPageSchema, learningRecordDetailSchema } = requireCore(join(core, 'src/household/learningApiContract.ts'))
const session = householdSessionSchema.parse({ ...preparation.ownerSession,
  capabilities: { ...preparation.ownerSession.capabilities, personalLearningArchive: true } })
const fixture = learningFixture(session)
const payload = fixture.detail.payload
fixture.detail.payloadHash = createHash('sha256').update(payload).digest('hex')
fixture.records.records[0].payloadBytes = Buffer.byteLength(payload)
fixture.archives.archives[0].payloadBytes = Buffer.byteLength(payload)
learningArchivePageSchema.parse(fixture.archives)
learningRecordPageSchema.parse(fixture.records)
learningRecordDetailSchema.parse(fixture.detail)
writeFileSync(output, JSON.stringify({ synthetic: true, sourceRevision, session, ...fixture }, null, 2) + '\n')
console.log('Generated private-learning contract examples; no device state was read.')
