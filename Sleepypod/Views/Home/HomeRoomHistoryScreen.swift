import SwiftUI
import UniformTypeIdentifiers

struct HomeRoomHistoryScreen: View {
    @Environment(HomeRoomSession.self) private var session
    @State private var export = RoomHistoryDocument(text: "")
    @State private var showExport = false
    @State private var exportError: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Historical measurements").font(.title3.bold())
                Text("Up to 30 days or 25,000 accepted reports are retained on the controller. These readings are historical and never supply current room values.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if let model = session.workspace {
                    if model.isSyntheticExample { Text("SYNTHETIC EXAMPLE · no household measurements.").font(.footnote).foregroundStyle(Theme.amber) }
                    if let error = model.historyError ?? exportError { Text(error).foregroundStyle(Theme.amber) }
                    Button("Reload history") { Task { await model.loadHistory() } }.disabled(model.loadingHistory)
                    Text("\(model.history.count) loaded reports").font(.footnote).foregroundStyle(Theme.text2)
                    if model.historyLoaded && model.history.isEmpty { Text("No accepted room reports yet.").accessibilityIdentifier("room.history.empty") }
                    if !model.history.isEmpty {
                        Button("Export loaded reports as JSON", systemImage: "square.and.arrow.up") {
                            do { export = .init(text: try model.historyJSON()); showExport = true; exportError = nil }
                            catch { exportError = error.localizedDescription }
                        }.accessibilityIdentifier("room.history.export")
                    }
                    ForEach(model.history) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(item.metric.title).font(.headline)
                            Text(item.available ? "\(item.value?.formatted(.number.precision(.fractionLength(0...1))) ?? "—") \(item.unit)" : "Unavailable")
                                .font(.title3.monospacedDigit())
                            Text(item.entityId).font(.caption.monospaced()).textSelection(.enabled)
                            Text("Configuration revision \(item.revision)").font(.caption).foregroundStyle(Theme.text2)
                            if let measured = item.measuredAt { Text("Measured \(HomeRoomSummaryCard.date(measured))").font(.caption) }
                            DisclosureGroup("Report timestamps") {
                                Text("Published \(HomeRoomSummaryCard.date(item.reportedAt))\nReceived \(HomeRoomSummaryCard.date(item.receivedAt))").font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    }
                    if model.nextHistory != nil {
                        Button(model.loadingHistory ? "Loading…" : "Load older reports") { Task { await model.loadHistory(older: true) } }.disabled(model.loadingHistory)
                    }
                } else { Text(session.setupError ?? "Room history unavailable.").foregroundStyle(Theme.text2) }
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Room history").navigationBarTitleDisplayMode(.inline)
            .task(id: session.workspace.map(ObjectIdentifier.init)) {
                showExport = false; export = .init(text: ""); exportError = nil
                await session.workspace?.loadHistory()
            }
            .fileExporter(isPresented: $showExport, document: export, contentType: .json, defaultFilename: "room-observations") { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
    }
}
private struct RoomHistoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
