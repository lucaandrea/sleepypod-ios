import SwiftUI

struct PersonalLearningRoute: Hashable, Identifiable { let id: String }

struct PersonalLearningScreen: View {
    let model: PersonalLearningWorkspace
    @State private var selection: PersonalLearningRoute?
    var body: some View {
        Form {
            Section {
                Text("History kept when you change sides stays private to your account. Browse your earlier check-ins, notes and saved models here.")
                    .font(.body).accessibilityIdentifier("learning.meaning")
                Text("Reading saved learning does not train a model or change your bed.").font(.footnote).foregroundStyle(Theme.text2)
            }
            PersonalLearningFeedback(model: model)
            if !model.enabled {
                Section { Text("This library is not enabled for your personal account. Return to your account and refresh to check availability.").accessibilityIdentifier("learning.unavailable") }
            } else if let page = model.archives {
                Section {
                    if page.archives.isEmpty {
                        Text("No preserved library yet").font(.headline).accessibilityIdentifier("learning.empty")
                        Text("A private copy is made during a completed, reviewed side change. This does not mean your current sleep recordings are missing.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                    ForEach(page.archives) { archive in
                        Button { selection = .init(id: archive.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Saved \(PersonalLearningPresentation.date(archive.capturedAt))").font(.headline)
                                    Text("\(archive.recordCount.formatted()) \(archive.recordCount == 1 ? "record" : "records") · original \(archive.sourceSide.rawValue.capitalized) arrangement")
                                        .font(.caption).foregroundStyle(Theme.text2)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text2).accessibilityHidden(true)
                            }.padding(.vertical, 4)
                        }.disabled(model.busy).accessibilityIdentifier("learning.archive.\(archive.id)")
                    }
                    if page.nextCursor != nil {
                        Button("Show older libraries") { Task { await model.olderArchives() } }.disabled(model.busy).accessibilityIdentifier("learning.older")
                    }
                }
            }
            if model.enabled {
                Section { Button("Reload library") { Task { await model.refresh() } }.disabled(model.busy).accessibilityIdentifier("learning.reload") }
            }
        }
        .modifier(PersonalLearningAccessCheck(model: model))
        .privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Saved learning").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selection) { selected in PersonalLearningRecordsScreen(model: model, archiveId: selected.id) }
        .task { if model.archives == nil { await model.refresh() } }
        .onChange(of: selection) { if selection == nil { model.closeArchive() } }
        .onDisappear { if selection == nil { model.suspend() } }
    }
}

struct PersonalLearningRecordsScreen: View {
    let model: PersonalLearningWorkspace
    let archiveId: String
    @State private var selection: PersonalLearningRoute?
    var body: some View {
        Form {
            Section {
                Text("Original sensor sides are retained. Saved models are historical copies, not approved training data.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            PersonalLearningFeedback(model: model)
            if let page = model.records, page.archiveId == archiveId {
                Section {
                    ForEach(page.records) { record in
                        Button { selection = .init(id: record.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(PersonalLearningPresentation.title(record)).font(.headline)
                                    Text(record.redacted ? "Content removed" : "Saved from \(record.sourceSide.rawValue.capitalized)")
                                        .font(.caption).foregroundStyle(Theme.text2)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text2).accessibilityHidden(true)
                            }.padding(.vertical, 4)
                        }.disabled(model.busy).accessibilityIdentifier("learning.record.\(record.id)")
                    }
                    if page.records.isEmpty { Text("No records remain on this page. Return to Saved learning and reload.") }
                    if page.nextOrdinal != nil {
                        Button("Show next records") { Task { await model.nextRecords() } }.disabled(model.busy).accessibilityIdentifier("learning.next")
                    }
                }
            } else if !model.busy {
                Section { Text("Return to Saved learning and reload to verify this library.").font(.footnote).foregroundStyle(Theme.text2) }
            }
        }
        .modifier(PersonalLearningAccessCheck(model: model))
        .privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Saved records").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selection) { selected in PersonalLearningDetailScreen(model: model, recordId: selected.id) }
        .task(id: archiveId) { if model.records?.archiveId != archiveId { await model.openArchive(archiveId) } }
        .onChange(of: selection) { if selection == nil { model.closeRecord() } }
    }
}

struct PersonalLearningFeedback: View {
    let model: PersonalLearningWorkspace
    var body: some View {
        if model.busy { Section { ProgressView(model.activity).accessibilityIdentifier("learning.loading") } }
        if let error = model.error { Section { Text(error).foregroundStyle(Theme.text1).accessibilityIdentifier("learning.error") } }
    }
}

struct PersonalLearningAccessCheck: ViewModifier {
    let model: PersonalLearningWorkspace
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content.task(id: scenePhase) {
            guard scenePhase == .active else { model.suspend(); return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await model.checkAccess()
            }
        }
    }
}
