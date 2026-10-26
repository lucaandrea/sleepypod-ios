// Run against contract.ts/homeAssistant.ts extracted from the recorded Core commit with Node 24/tsx.
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

async function main() {
  const directory = resolve(process.argv[2])
  const { roomStatusSchema, historyItemSchema } = await import(pathToFileURL(resolve(directory, 'contract.ts')).href)
  const { homeAssistantAutomations } = await import(pathToFileURL(resolve(directory, 'homeAssistant.ts')).href)
  const generatedAt = 1800000000000
  const mapping = (metric: string, unit: string) => ({ metric, entityId: `sensor.example_${metric}`, unit,
    timestampAttribute: 'measured_at', timestampFormat: 'iso8601', maxAgeSeconds: 120 })
  const config = { enabled: true, roomName: 'Synthetic bedroom', mappings: [mapping('temperature', '°C'), mapping('humidity', '%'), mapping('co2', 'ppm')] }
  const observations = config.mappings.map((item, index) => ({ metric: item.metric, entityId: item.entityId, unit: index === 0 ? '°F' : item.unit,
    value: [71.6, 45, 650][index], lastValue: [71.6, 45, 650][index], measuredAt: generatedAt - 10000,
    reportedAt: generatedAt - 9000, receivedAt: generatedAt - 8000, expiresAt: generatedAt + 110000, status: 'fresh' }))
  const status = roomStatusSchema.parse({ apiVersion: 1, generatedAt, revision: 7, config, connected: true,
    topic: 'example/controller/room/report', observations })
  const history = { apiVersion: 1, generatedAt, nextBeforeId: null, items: observations.map((item, index) => historyItemSchema.parse({
    id: 10 - index, revision: 7, metric: item.metric, entityId: item.entityId, unit: item.unit, measuredAt: item.measuredAt,
    reportedAt: item.reportedAt, receivedAt: item.receivedAt, value: item.value, available: true })) }
  const publishers = { revision: 7, automations: homeAssistantAutomations(status, status.topic).map((item: unknown) => JSON.stringify(item, null, 2)) }
  writeFileSync(process.argv[3], JSON.stringify({ sourceCommit: 'cbb0e5bd45c723888e44e8506ef91fdf9b380630', synthetic: true, status, history, publishers }, null, 2) + '\n')
  console.log(JSON.stringify({ metrics: observations.map(item => item.metric), publishers: publishers.automations.length }))
}
main().catch(error => { console.error(error); process.exitCode = 1 })
