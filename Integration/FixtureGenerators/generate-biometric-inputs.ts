import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

/** Regenerate linked synthetic metadata using Core in an isolated in-memory database. */
async function main() {
  const coreDirectory = resolve(process.argv[2] ?? '../sleepypod-core')
  const outputDirectory = resolve(process.argv[3] ?? fileURLToPath(new URL('../Fixtures/', import.meta.url)))
  mkdirSync(outputDirectory, { recursive: true })
  const importCore = (relativePath: string) => import(pathToFileURL(join(coreDirectory, relativePath)).href)
  const { RawSourceCatalog } = await importCore('src/biometrics/backtest/raw-catalog.ts')
  const { prepareSelectedWaveformDataset } = await importCore('src/biometrics/backtest/waveform-selection.ts')
  const requireCore = createRequire(join(coreDirectory, 'package.json'))
  const Database = requireCore('better-sqlite3')
  const { drizzle } = requireCore('drizzle-orm/better-sqlite3')
  const { migrate } = requireCore('drizzle-orm/better-sqlite3/migrator')
  const schema = await importCore('src/db/biometrics-schema.ts')
  const { DatasetStore } = await importCore('src/biometrics/backtest/datasets.ts')
  const { ReferenceStore } = await importCore('src/biometrics/references/store.ts')
  const { previewReferenceImport } = await importCore('src/biometrics/references/normalize.ts')
  const { listReplaySessions, sessionCapabilities } = await importCore('src/biometrics/backtest/discovery.ts')
  const sqlite = new Database(':memory:')
  const database = drizzle(sqlite, { schema })
  migrate(database, { migrationsFolder: join(coreDirectory, 'src/db/biometrics-migrations') })
  const createdAt = Date.parse('2026-10-25T12:00:00Z')
  const datasets = new DatasetStore(database, () => createdAt)
  const references = new ReferenceStore(database, () => createdAt)
  const result = []
  const waveformFixtures = []
  const catalog = new RawSourceCatalog(database, () => createdAt)
  for (let index = 0; index < 2; index++) {
    const startMs = Date.parse('2026-10-22T22:00:00Z') + index * 86400000
    const digest = createHash('sha256').update(`synthetic-waveform-${index}`).digest('hex')
    catalog.record({ source_name: `synthetic-night-${index + 1}.RAW.gz`, retained: false,
      artifact: { name: `${digest}.RAW.gz`, sha256: digest, compressed_bytes: 1024, expanded_bytes: 4096 },
      inventory: { version: 'retained-raw-inventory-v1', artifact_sha256: digest,
        decoded_records: 3, piezo_records: 2, pump_records: 1, usable_dual_frames: 2, empty_channel_frames: 0,
        oversize_channel_frames: 0, invalid_timestamps: 0, timestamp_reversals: 0, duplicate_timestamps: 0,
        first_event_ms: startMs - 300000, last_event_ms: startMs + 7200000 - 1,
        channels: { left1: { samples: 20, lost_markers: 1, truncated_tail_bytes: 0 }, right1: { samples: 20, lost_markers: 0, truncated_tail_bytes: 0 } },
        ordered_waveform_available: true, limitations: ['Synthetic metadata only; no RAW bytes were read or retained.', 'Event bounds do not establish continuous coverage.'] }
    })
  }
  for (const [sideIndex, side] of ['left', 'right'].entries()) {
    const firstId = 100 + sideIndex * 10
    const startMs = Date.parse('2026-10-22T22:00:00Z')
    for (let index = 0; index < 3; index++) {
      const entered = startMs + index * 86400000
      database.insert(schema.sleepRecords).values({ id: firstId + index, side, enteredBedAt: new Date(entered), leftBedAt: new Date(entered + 7200000), sleepDurationSeconds: 6600, timesExitedBed: 1 }).run()
      if (index === 2) continue
      for (const minute of [0, 1, 4, 60, 61, 90]) {
        database.insert(schema.vitals).values({ side, timestamp: new Date(entered + minute * 60000), heartRate: 60 + index, breathingRate: 15 }).run()
        database.insert(schema.movement).values({ side, timestamp: new Date(entered + minute * 60000), totalMovement: 2 }).run()
      }
    }
    const input = { side, subjectId: 'demo-sleeper', source: 'Synthetic reference', rows: [
      { recordKey: 'demo-hr', metric: 'heart_rate', value: 60, unit: 'bpm', timestampMs: startMs, annotation: 'Synthetic example only' }
    ] }
    const reference = references.commit({ import: input, previewHash: previewReferenceImport(input).summary.contentHash })
    const snapshots = []
    for (const sessionIds of [[firstId], [firstId + 1], [firstId, firstId + 1]]) {
      for (const referenceImportIds of [[], [reference.id]]) {
        const selection = { side, subjectId: 'demo-sleeper', sessionIds, referenceImportIds }
        const descriptor = datasets.create({ ...selection, timezone: 'America/Los_Angeles', idempotencyKey: JSON.stringify(selection) })
        const pages = descriptor.manifest.splitProtocol.assignments.map(cohort => ({ cohortId: cohort.cohortId,
          page: catalog.page({ startMs: Math.max(0, cohort.startMs - 300000), endMs: cohort.endMs }) }))
        const request = { parentDatasetId: descriptor.id, expectedContentHash: descriptor.contentHash,
          cohorts: pages.map(item => ({ cohortId: item.cohortId, sourceIds: item.page.items.map(source => source.id).sort() })),
          idempotencyKey: `synthetic-waveform-${descriptor.id}` }
        const { prepared } = prepareSelectedWaveformDataset(database, request, createdAt + 1)
        const waveform = { id: prepared.id, side: prepared.side, subjectId: prepared.subjectId, contentHash: prepared.contentHash,
          manifest: prepared.manifest, byteLength: Buffer.byteLength(JSON.stringify(prepared.snapshot)) + Buffer.byteLength(JSON.stringify(prepared.manifest)),
          createdAtMs: prepared.createdAtMs, releasedAtMs: null, available: true }
        waveformFixtures.push({ parentId: descriptor.id, request, pages, descriptor: waveform,
          releasedByteLength: Buffer.byteLength(JSON.stringify(waveform.manifest)) + Buffer.byteLength(JSON.stringify({ released: true })) })
        const released = datasets.release(descriptor.id)
        snapshots.push({ selection, descriptor, releasedByteLength: released.byteLength })
      }
    }
    const sessions = listReplaySessions(database, side)
    result.push({ side, sessions, capabilities: sessions.items.map(session => sessionCapabilities(database, side, session.id)), references: { items: [reference], nextCursor: null }, snapshots })
  }
  sqlite.close()
  writeFileSync(join(outputDirectory, 'dataset-demo.json'), JSON.stringify(result, null, 2) + '\n')


  writeFileSync(join(outputDirectory, 'waveform-demo.json'), JSON.stringify(waveformFixtures, null, 2) + '\n')
  console.log('Generated 12 linked synthetic manifest pairs. No RAW files were read or retained.')
}

main().catch(error => { console.error(error); process.exitCode = 1 })
