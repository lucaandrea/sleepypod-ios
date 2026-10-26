import Charts
import SwiftUI

struct SystemDatabaseScreen: View {
    @State private var model: SystemDatabaseWorkspace
    @State private var backupTask: Task<Void, Never>?
    private let client: any SystemDatabaseClient
    init(client: (any SystemDatabaseClient)? = nil) {
        let chosen = client ?? (APIBackend.current.isDemo ? DemoSystemDatabaseClient() : CoreSystemDatabaseClient())
        self.client = chosen; _model = State(initialValue: SystemDatabaseWorkspace(client: chosen))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if APIBackend.current.isDemo { Text("DEMO · simulated database inventory and rows").font(.footnote).foregroundStyle(Theme.amber) }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("database.error") }
                if model.loading { ProgressView("Inspecting databases…") }
                if let overview = model.overview {
                    Text("\(overview.databases.count) databases · \(databaseBytes(overview.totalBytes)) including WAL").font(.headline)
                    Text("Measured \(overview.date.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(Theme.text2)
                    if model.error != nil { Text("Showing the last successful inventory.").font(.footnote).foregroundStyle(Theme.amber) }
                    SystemDatabaseOutlookCard(overview: overview)
                    ForEach(overview.databases) { database in
                        SystemDatabaseCard(database: database, overview: overview, client: client)
                    }
                    GroupedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Integrity and backup").font(.headline)
                            Button(model.checking ? "Checking…" : "Run integrity check") { Task { await model.checkIntegrity() } }
                                .disabled(model.checking || APIBackend.current.isDemo).accessibilityIdentifier("database.integrity")
                            if let checks = model.integrityResult {
                                ForEach(checks.keys.sorted(), id: \.self) { key in
                                    if let check = checks[key] { Text("\(key): \(check.status) · \(Int(check.latencyMs)) ms").foregroundStyle(check.status == "ok" ? Theme.green : Theme.amber) }
                                }
                            }
                            Text("Online backup copies both databases while the Pod keeps running. The archive contains your settings and sleep records.").font(.footnote).foregroundStyle(Theme.text2)
                            if let last = overview.lastBackupAt { Text("Last controller backup: \(Date(timeIntervalSince1970: last / 1000).formatted())").font(.footnote) }
                            Button(model.downloading ? "Preparing backup…" : "Download database backup") { backupTask = Task { await model.downloadBackup() } }
                                .disabled(model.downloading || APIBackend.current.isDemo)
                            if let file = model.backupURL {
                                ShareLink(item: file) { Label("Save or share backup", systemImage: "square.and.arrow.up") }
                            }
                            Text("Restore requires stopping sleepypod and copying each .db into \(overview.dataDir).").font(.footnote).foregroundStyle(Theme.text2).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                } else if !model.loading { ContentUnavailableView("Inventory unavailable", systemImage: "externaldrive", description: Text("Refresh when your controller is reachable.")) }
                Button("Refresh database inventory") { Task { await model.load(fresh: true) } }.disabled(model.loading)
            }.padding(16)
        }.background(Theme.background).navigationTitle("Databases").navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }.refreshable { await model.load(fresh: true) }
            .onDisappear { backupTask?.cancel(); model.removeBackup() }
    }
}

func databaseBytes(_ bytes: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(max(0, min(bytes, Double(Int64.max / 2)))), countStyle: .file) }

private struct SystemDatabaseCard: View {
    let database: SystemDatabase
    let overview: SystemDatabaseOverview
    let client: any SystemDatabaseClient
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(database.key.rawValue).db").font(.headline)
                Text(database.path).font(.caption).foregroundStyle(Theme.text2).textSelection(.enabled)
                if let error = database.error { Text(error).foregroundStyle(Theme.amber) }
                LabeledContent("Database", value: databaseBytes(database.fileBytes))
                LabeledContent("Write-ahead log", value: databaseBytes(database.walBytes))
                LabeledContent("Reusable pages", value: "\(Int(database.freePages)) · \(databaseBytes(database.freePages * database.pageSize))")
                LabeledContent("Page size", value: databaseBytes(database.pageSize))
                LabeledContent("WAL checkpoint", value: "\(Int(database.walAutocheckpoint)) pages")
                integrity("Scheduled check", database.integrity.scheduled)
                integrity("Manual check", database.integrity.manual)
                Text("Migrations: \(database.migrations.applied)/\(database.migrations.known) · \(database.migrations.note)").font(.footnote)
                Divider()
                Text("Tables").font(.headline)
                ForEach(database.tables) { table in
                    NavigationLink {
                        SystemDatabaseTableScreen(database: database.key, table: table, overview: overview, client: client)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(table.name).font(.subheadline.weight(.medium))
                            Text("\(table.rows.formatted()) rows · \(databaseBytes(table.bytes))").font(.caption).foregroundStyle(Theme.text2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }.accessibilityIdentifier("database.table.\(database.key.rawValue).\(table.name)")
                }
            }.padding(16)
        }
    }
    @ViewBuilder private func integrity(_ label: String, _ run: SystemDatabase.IntegrityRun?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(label): \(run?.status ?? "Not checked")").foregroundStyle(run?.status == "degraded" ? Theme.amber : Theme.text1)
            if let run {
                Text("\(run.checkedAt ?? "No check time") · \(Int(run.latencyMs)) ms").font(.caption).foregroundStyle(Theme.text2)
                if let error = run.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            }
        }
    }
}

private struct SystemDatabaseOutlookCard: View {
    let overview: SystemDatabaseOverview
    var body: some View {
        let tables = overview.databases.flatMap(\.tables)
        let outlook = SystemDatabaseOutlook(tables: tables, availableBytes: overview.disk?.availableBytes)
        GroupedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Storage outlook").font(.headline)
                if let disk = overview.disk { Text("\(databaseBytes(disk.availableBytes)) available of \(databaseBytes(disk.totalBytes))") }
                else { Text("Free disk space is unknown.").foregroundStyle(Theme.amber) }
                if let days = outlook.fillDays { Text("At the last 24 hours’ write rate, database growth would use the available space in about \(days) days.").foregroundStyle(Theme.amber) }
                else if outlook.availableBytes != nil { Text("This projection does not exhaust available space within ten years.") }
                Text("Unpruned growth: \(databaseBytes(outlook.growingPerDay))/day").font(.footnote)
                Chart(outlook.samples) { sample in
                    AreaMark(x: .value("Days ahead", sample.day), y: .value("Projected bytes", sample.bytes)).foregroundStyle(Theme.cool.opacity(0.2))
                    LineMark(x: .value("Days ahead", sample.day), y: .value("Projected bytes", sample.bytes)).foregroundStyle(Theme.cool)
                }.chartXAxisLabel("Days ahead").chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(); AxisValueLabel { if let bytes = value.as(Double.self) { Text(databaseBytes(bytes)) } }
                } }.frame(height: 190).accessibilityLabel("Projected database size")
                Text("Estimate from table size, new rows in the last 24 hours and configured retention. It excludes other disk use, WAL changes and future changes in recording.").font(.caption).foregroundStyle(Theme.text2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
}
