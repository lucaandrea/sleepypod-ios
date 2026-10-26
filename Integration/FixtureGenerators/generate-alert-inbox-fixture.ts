// Extract contract.ts and foreground.ts from the recorded Core revision; run with Node 24/tsx.
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

async function main() {
  const source = resolve(process.argv[2])
  const { notificationPageSchema } = await import(pathToFileURL(resolve(source, 'contract.ts')).href)
  const { foregroundDelivery } = await import(pathToFileURL(resolve(source, 'foreground.ts')).href)
  const generatedAt = 1800000000000
  const page = (ids: number[], read: number[] = []) => notificationPageSchema.parse({
    apiVersion: 1, generatedAt, newestId: Math.max(...ids), nextBeforeId: null,
    unreadCount: ids.filter(id => !read.includes(id)).length,
    items: ids.map(id => ({ id, source: 'automation', sourceId: 12, title: 'Synthetic reminder', message: 'Literal <example> message',
      createdAt: generatedAt - 1000, expiresAt: generatedAt + 899000, acknowledgedAt: read.includes(id) ? generatedAt : null })),
    delivery: { foregroundInbox: true, backgroundPush: false },
  })
  let cursor: number | null | undefined
  const steps = [page([3, 2]), page([5, 4, 3], [4]), page([2, 1]), page([5, 4, 3]), page([6, 5])].map(value => {
    const expected = foregroundDelivery(value, cursor)
    cursor = expected.cursor
    return { page: value, expected }
  })
  writeFileSync(process.argv[3], JSON.stringify({ sourceCommit: '7fa390a75ce3358e39d59ac016b66c0d38144ac3', synthetic: true, steps }, null, 2) + '\n')
  console.log(JSON.stringify(steps.map(step => ({ cursor: step.expected.cursor, announced: step.expected.items.map((item: { id: number }) => item.id) }))))
}
main().catch(error => { console.error(error); process.exitCode = 1 })
