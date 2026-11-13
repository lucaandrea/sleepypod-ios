import { writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// Only pure Core contracts are loaded; no database, service or hardware is started.
const core = resolve(process.argv[2] ?? '../sleepypod-core')
const output = resolve(process.argv[3] ?? fileURLToPath(new URL('../Fixtures/household-maintenance-v1.json', import.meta.url)))
if (execFileSync('git', ['-C', core, 'status', '--porcelain', '--untracked-files=no'], { encoding: 'utf8' }).trim())
  throw new Error('Use a tracked-clean Core checkout for fixture provenance.')
const sourceCommit = execFileSync('git', ['-C', core, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
const requireCore = createRequire(join(core, 'package.json'))
const { arrangementMaintenanceStatusSchema: status } = requireCore(join(core, 'src/household/arrangementMaintenanceContract.ts'))
const { arrangementCancellationPreviewSchema: preview } = requireCore(join(core, 'src/household/arrangementCancellationContract.ts'))
const now = 1_794_337_200_000
const operationId = '10000000-0000-4000-8000-000000000088'
const reviewId = '10000000-0000-4000-8000-000000000041'
const requestId = '10000000-0000-4000-8000-000000000089'
const operation = { operationId, reviewId, state: 'held', createdAt: now - 4000, committedAt: null,
  controllerRestarted: false, admission: 'held_for_this_transition', recovery: null, cancellation: null, restart: null }
const page = (current: unknown) => status.parse({ version: 1, observedAt: now,
  expectedSessionRevision: 1, expectedAssignmentRevision: 1, operation: current })
const committed = { ...operation, state: 'committed', committedAt: now - 3000 }
const restart = { operationId, requestId, state: 'submitted', requestedAt: now - 2000,
  resultAt: now - 1500, hardware: 'held_for_runtime_recovery', replayAllowed: false }
const common = { operationId, requestId, reviewId, completedAt: now - 100, admissionRevision: 3,
  hardware: 'admission_released', physicalMovement: 'not_requested' }
const recovery = { ...common, state: 'completed', epochId: requestId, recordingStartsAt: now - 500 }
const cancellation = { ...common, state: 'cancelled', controlDigest: 'a'.repeat(64), arrangement: 'solo-anywhere' }
const cases = { empty: page(null), held: page(operation), committed: page(committed),
  restartSubmitted: page({ ...committed, restart }), readyToRecover: page({ ...committed, restart, controllerRestarted: true }),
  completed: page({ ...committed, restart, recovery, state: 'completed', controllerRestarted: true, admission: 'open' }),
  cancelled: page({ ...operation, restart, cancellation, state: 'cancelled', controllerRestarted: true, admission: 'open' }),
  cancellationPreview: preview.parse({ operationId, expectedSessionRevision: 1, expectedAssignmentRevision: 1,
    controlDigest: 'a'.repeat(64), observedAt: now }) }
const context = { version: 1, requestId, expectedSessionRevision: 1, expectedAssignmentRevision: 1,
  issuedAt: now, expiresAt: now + 60_000, confirmEmptyAndAttended: true }
const requests = {
  activateRequest: requireCore(join(core, 'src/household/arrangementTransitionContract.ts')).arrangementTransitionRequestSchema.parse({
    ...context, reviewId, confirmClearTemporaryActions: true, confirmPauseLearningAndSharedAutomations: true, acknowledgeHeldUntilRecovery: true }),
  restartRequest: requireCore(join(core, 'src/household/arrangementRestartContract.ts')).arrangementRestartRequestSchema.parse({
    ...context, operationId, acknowledgeConnectionWillClose: true, acknowledgeControlsRemainPaused: true }),
  recoverRequest: requireCore(join(core, 'src/household/arrangementRecoveryContract.ts')).arrangementRecoveryRequestSchema.parse({
    ...context, operationId, confirmAssignedSides: true, acknowledgeRecordingGap: true, acknowledgeLearningRemainsOff: true }),
  cancelRequest: requireCore(join(core, 'src/household/arrangementCancellationContract.ts')).arrangementCancellationRequestSchema.parse({
    ...context, operationId, expectedControlDigest: 'a'.repeat(64), confirmKeepSoloArrangement: true, acknowledgeSavedRoutinesMayResume: true }),
}
writeFileSync(output, JSON.stringify({ synthetic: true, sourceCommit, now, ...cases, ...requests }, null, 2) + '\n')
console.log('Generated eight projections and four requests from Core contracts; no device state was read.')
