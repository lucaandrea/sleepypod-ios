import Charts
import SwiftUI
import UniformTypeIdentifiers

struct SystemDatabaseTableScreen: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let database: SystemDatabase.Key
    let table: SystemDatabase.Table
    let overview: SystemDatabaseOverview
    let client: any SystemDatabaseClient
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupedCard {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Rows", value: table.rows.formatted())
                        LabeledContent("Size", value: databaseBytes(table.bytes))
                        LabeledContent("Rows in last 24 hours", value: table.rows24h.formatted())
                        LabeledContent("Estimated growth", value: "\(databaseBytes(table.dailyGrowth))/day")
                        if let retention = table.retention { Text("Retained for \(retention.days.formatted()) days · \(retention.by)") }
                        else { Text(table.dailyGrowth >= 4096 ? "Not pruned · continues to grow at the current rate" : "No automatic retention").foregroundStyle(table.dailyGrowth >= 4096 ? Theme.amber : Theme.text2) }
                        if let time = table.lastWriteAt { Text("Last write: \(Date(timeIntervalSince1970: time / 1000).formatted())") }
                        else { Text("Last write time unknown").foregroundStyle(Theme.text2) }
                        if let time = table.oldestAt { Text("Oldest: \(Date(timeIntervalSince1970: time / 1000).formatted())") }
                        Text("Time column: \(table.timeColumn ?? "None")").font(.footnote)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                GroupedCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hourly writes").font(.headline)
                        Text("From \(Date(timeIntervalSince1970: overview.hoursFrom / 1000).formatted(date: .abbreviated, time: .shortened)) · your local time").font(.caption).foregroundStyle(Theme.text2)
                        Chart(Array(table.hourly.enumerated()), id: \.offset) { hour, count in
                            BarMark(x: .value("Hour", Date(timeIntervalSince1970: overview.hoursFrom / 1000 + Double(hour) * 3600)), y: .value("Rows", max(count, 1)))
                                .foregroundStyle(table.missingHour(hour, occupied: Set(overview.occupiedHours)) ? Theme.amber : count > 0 ? Theme.cool : Theme.text2.opacity(0.15))
                        }.chartXAxis {
                            AxisMarks(values: [0, 12, 23].map { Date(timeIntervalSince1970: overview.hoursFrom / 1000 + Double($0) * 3600) }) { _ in
                                AxisGridLine(); AxisValueLabel(format: .dateTime.hour())
                            }
                        }.chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                            .frame(height: typeSize.isAccessibilitySize ? 240 : 160).accessibilityLabel("Hourly table writes")
                        Text("Blue: writes · gray: idle · amber: an occupied hour with no vitals. Idle bars use a minimum height for visibility.").font(.caption).foregroundStyle(Theme.text2)
                    }.padding(16)
                }
                NavigationLink {
                    SystemDatabaseRowsScreen(database: database, table: table, client: client)
                } label: { Label("Browse rows", systemImage: "tablecells") }.accessibilityIdentifier("database.browse")
            }.padding(16)
        }.background(Theme.background).navigationTitle(table.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct SystemDatabaseRowsScreen: View {
    private let table: SystemDatabase.Table
    @State private var model: SystemDatabaseRowsWorkspace
    @State private var columns: [String] = []
    @State private var column = ""
    @State private var value = ""
    @State private var copied = false
    @State private var exporting = false
    @State private var exportError: String?
    @FocusState private var filterFocused: Bool
    init(database: SystemDatabase.Key, table: SystemDatabase.Table, client: any SystemDatabaseClient) {
        self.table = table; _model = State(initialValue: SystemDatabaseRowsWorkspace(query: .init(database: database, table: table.name), client: client))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Read-only · newest rows first").font(.footnote).foregroundStyle(Theme.text2)
                if APIBackend.current.isDemo { Text("DEMO · simulated rows").font(.footnote).foregroundStyle(Theme.amber) }
                GroupedCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Filter column", selection: $column) {
                            Text("All rows").tag("")
                            ForEach(columns, id: \.self) { Text($0).tag($0) }
                        }.accessibilityIdentifier("database.column")
                        if !column.isEmpty {
                            TextField("Exact value", text: $value).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never).focused($filterFocused)
                                .submitLabel(.search).onSubmit { applyFilter() }.accessibilityIdentifier("database.filterValue")
                        }
                        Button("Apply filter") { applyFilter() }.disabled(model.loading).accessibilityIdentifier("database.applyFilter")
                    }.padding(16)
                }
                if model.loading { ProgressView("Reading rows…") }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber) }
                if let result = model.result {
                    Text("\(result.total.formatted()) matching rows · page \(model.query.offset / model.query.limit + 1)").font(.headline).accessibilityIdentifier("database.rowCount")
                    if let filter = model.query.column { Text("Applied: \(filter) = \(model.query.value ?? "")").font(.footnote).textSelection(.enabled) }
                    ViewThatFits(in: .horizontal) { pageControls(result); VStack(alignment: .leading, spacing: 10) { previous; next(result) } }
                    if result.rows.isEmpty { Text("No rows returned for this page.").foregroundStyle(Theme.text2) }
                    ForEach(Array(result.rows.enumerated()), id: \.offset) { rowIndex, row in
                        GroupedCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Row \(model.query.offset + rowIndex + 1)").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                                ForEach(Array(result.columns.enumerated()), id: \.offset) { index, title in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(title).font(.caption).foregroundStyle(Theme.text2)
                                        if row.indices.contains(index) {
                                            Text(row[index].display).font(.body.monospaced()).textSelection(.enabled)
                                            if title == result.timeColumn, case .number(let time) = row[index] {
                                                Text(Date(timeIntervalSince1970: table.timeInMs ? time / 1000 : time).formatted()).font(.caption).foregroundStyle(Theme.text2)
                                            }
                                        } else { Text("Missing cell").foregroundStyle(Theme.amber) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(16)
                        }
                    }
                    Button(copied ? "Copied page CSV" : "Copy page as CSV") { UIPasteboard.general.string = result.csv; copied = true }
                    Button("Export page CSV") { exporting = true }
                    if let exportError { Text(exportError).foregroundStyle(Theme.amber) }
                    Text("CSV includes this page only. Text cells that could run spreadsheet formulas are prefixed with an apostrophe.").font(.caption).foregroundStyle(Theme.text2)
                }
                Button("Refresh rows") { Task { await model.load() } }.disabled(model.loading)
            }.padding(16)
        }.background(Theme.background).navigationTitle("\(table.name) rows").navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
            .onChange(of: model.result?.columns) { _, value in if let value { columns = value; copied = false } }
            .fileExporter(isPresented: $exporting, document: DatabaseCSVDocument(text: model.result?.csv ?? ""), contentType: .commaSeparatedText, defaultFilename: "\(table.name)-page-\(model.query.offset / model.query.limit + 1)") { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
    }
    private func pageControls(_ result: SystemDatabaseRows) -> some View { HStack { previous; Spacer(); next(result) } }
    private func applyFilter() {
        filterFocused = false
        var query = model.query; query.offset = 0; query.column = column.isEmpty ? nil : column; query.value = column.isEmpty ? nil : value
        Task { await model.load(query) }
    }
    private var previous: some View {
        Button("Previous page") { var query = model.query; query.offset = max(0, query.offset - query.limit); Task { await model.load(query) } }.disabled(model.loading || model.query.offset == 0)
    }
    private func next(_ result: SystemDatabaseRows) -> some View {
        Button("Next page") { var query = model.query; query.offset += query.limit; Task { await model.load(query) } }.disabled(model.loading || model.query.offset + model.query.limit >= result.total).accessibilityIdentifier("database.nextPage")
    }
}

private struct DatabaseCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
