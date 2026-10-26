import SwiftUI

struct SystemStorageScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: SystemStorageWorkspace
    @State private var includeBackups = false
    @State private var selected: StorageCleanupSelection?
    @State private var confirming = false
    init(client: (any SystemStorageClient)? = nil) {
        _model = State(initialValue: .init(client: client ?? (APIBackend.current.isDemo ? DemoSystemStorageClient() : CoreSystemStorageClient())))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if APIBackend.current.isDemo { Text("DEMO · simulated storage and cleanup").font(.footnote).foregroundStyle(Theme.amber) }
                if let error = model.error { Text("Storage: \(error). Any retained report may be stale.").foregroundStyle(Theme.amber) }
                if let report = model.report {
                    usage(report)
                    cleanup(report)
                } else if model.loading { ProgressView("Reading storage…") }
                if let received = model.receivedAt { Text("Report received \(received.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(Theme.text2) }
                Button("Refresh storage") { Task { await model.load() } }.disabled(model.loading || model.cleaning)
            }.padding(16)
        }.accessibilityIdentifier("storage.content").background(Theme.background).navigationTitle("Storage").navigationBarTitleDisplayMode(.inline)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    await model.load()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                } while !Task.isCancelled
            }
            .alert("Delete eligible leftovers?", isPresented: $confirming) {
                Button("Delete", role: .destructive) { if let selected { Task { await model.clean(selected) } } }
                Button("Cancel", role: .cancel) { selected = nil }
            } message: {
                if let selected {
                    Text("The report lists \(selected.items.count) items (\(SystemStorage.bytes(selected.bytes))). Core rechecks eligible leftovers before permanently deleting them, so the final amount can change. \(selected.includeBackups ? "Old database backups are included; the newest of each is kept." : "Database backups are excluded.") The running app, live databases, raw archive, swap and HomeKit pairing are preserved.")
                }
            }
    }
    private func usage(_ report: SystemStorage) -> some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("/persistent", systemImage: "internaldrive").font(.headline)
                if report.persistent.totalBytes > 0 {
                    Text("\(SystemStorage.bytes(report.persistent.usedBytes)) of \(SystemStorage.bytes(report.persistent.totalBytes)) used · \(SystemStorage.bytes(report.persistent.availableBytes)) free").font(.subheadline.monospacedDigit())
                    usageBar(report)
                    ForEach(report.segments) { segment in
                        Label { Text("\(segment.title) · \(SystemStorage.bytes(segment.bytes))").font(.subheadline) } icon: { RoundedRectangle(cornerRadius: 2).fill(color(segment.key)).frame(width: 10, height: 10) }
                    }
                } else { Text("Storage capacity is unavailable on this device.").foregroundStyle(Theme.text2) }
                Text(report.rawHistory.days.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) days of raw history · \(report.rawHistory.fileCount) archives" } ?? (report.rawHistory.fileCount == 0 ? "No raw archive yet" : "\(report.rawHistory.fileCount) archives · duration unknown")).font(.footnote)
                if let oldest = SensorCalibrationProfile.date(report.rawHistory.oldest), let newest = SensorCalibrationProfile.date(report.rawHistory.newest) {
                    Text("\(oldest.formatted(date: .abbreviated, time: .omitted)) → \(newest.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(Theme.text2)
                }
                Text("The pruner keeps /persistent under \(report.prunerTargetPercent.formatted(.number.precision(.fractionLength(0...1))))% by deleting the oldest raw archives. Leftover files reduce the space available for that history.").font(.footnote).foregroundStyle(Theme.text2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func usageBar(_ report: SystemStorage) -> some View {
        GeometryReader { geometry in
            let total = max(1, report.persistent.totalBytes)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.active)
                HStack(spacing: 0) {
                    ForEach(report.segments) { segment in
                        Rectangle().fill(color(segment.key)).frame(width: geometry.size.width * min(1, max(0, segment.bytes / total)))
                    }
                    Spacer(minLength: 0)
                }.clipShape(Capsule())
                Rectangle().fill(Theme.text1).frame(width: 2).offset(x: min(geometry.size.width - 2, geometry.size.width * min(1, max(0, report.prunerTargetPercent / 100))))
            }.clipped()
        }.frame(height: 12).accessibilityLabel("\(report.persistent.usedPercent.formatted(.number.precision(.fractionLength(1)))) percent used; pruner target \(report.prunerTargetPercent.formatted()) percent")
    }
    private func cleanup(_ report: SystemStorage) -> some View {
        let items = report.selected(includeBackups: includeBackups)
        return GroupedCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("Reclaimable", systemImage: "trash").font(.headline)
                if !report.reclaimable.available { Text("Cleanup tool is not installed. Update the Pod to enable it.").font(.footnote).foregroundStyle(Theme.text2) }
                else if items.isEmpty { Text("Nothing to clean up.").foregroundStyle(Theme.text2).accessibilityIdentifier("storage.empty") }
                else { Text("\(items.count) eligible items in this report").font(.subheadline) }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.shortPath).font(.footnote.monospaced()).textSelection(.enabled)
                        Text(item.reason).font(.caption).foregroundStyle(Theme.text2)
                        Text(SystemStorage.bytes(item.bytes)).font(.caption.monospacedDigit())
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                if report.backupCount > 0 {
                    backupToggle(count: report.backupCount)
                    Text("The newest backup of each database is always kept.").font(.caption).foregroundStyle(Theme.text2)
                }
                if report.reclaimable.available, !items.isEmpty {
                    Button("Review cleanup · \(SystemStorage.bytes(items.reduce(0) { $0 + $1.bytes }))") {
                        selected = model.selection(includeBackups: includeBackups)
                        confirming = selected != nil
                    }.disabled(model.selection(includeBackups: includeBackups) == nil).accessibilityIdentifier("storage.review")
                }
                if model.cleaning { ProgressView("Cleaning eligible leftovers…") }
                if let result = model.result { Text("Freed \(SystemStorage.bytes(result.freedBytes)) from \(result.removed) items.").foregroundStyle(Theme.green).accessibilityIdentifier("storage.result") }
                if let error = model.actionError { Text(error).foregroundStyle(Theme.amber) }
                if model.mustReload { Text("Refresh storage before reviewing another cleanup.").font(.footnote).foregroundStyle(Theme.text2) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    @ViewBuilder private func backupToggle(count: Int) -> some View {
        let title = "Include \(count) old database \(count == 1 ? "backup" : "backups")"
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                Toggle(title, isOn: $includeBackups).labelsHidden().accessibilityLabel(title)
                    .disabled(model.cleaning).accessibilityIdentifier("storage.backups")
            }
        } else {
            Toggle(title, isOn: $includeBackups).disabled(model.cleaning).accessibilityIdentifier("storage.backups")
        }
    }
    private func color(_ key: String) -> Color {
        switch key {
        case "rawArchive": Theme.cool
        case "app": Theme.purple
        case "database": Theme.green
        case "swap": Theme.warm
        case "reclaimable": Theme.amber
        default: Theme.text3
        }
    }
}
