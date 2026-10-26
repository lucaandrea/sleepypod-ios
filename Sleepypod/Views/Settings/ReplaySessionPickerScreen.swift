import SwiftUI

struct ReplaySessionPickerScreen: View {
    let client: any BiometricDatasetsServing
    let draft: BiometricDatasetDraft
    @Environment(SettingsManager.self) private var settings
    @State private var page: ReplaySessionPage?
    @State private var cursor: ReplaySessionPage.Cursor?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Inspect available data before selecting sessions. Times use your Pod’s timezone: \(settings.timeZone).").font(.footnote).foregroundStyle(Theme.text2)
                Text("\(draft.selectedSessions.count) / 60 sessions selected").font(.headline)
                if !draft.selectedSessions.isEmpty {
                    DisclosureGroup("Selected sessions") {
                        ForEach(draft.selectedSessions.keys.sorted(), id: \.self) { identifier in
                            Button("Remove session \(identifier)", role: .destructive) { draft.removeSession(identifier) }
                        }
                    }.cardStyle()
                }
                if loading { ProgressView("Loading recorded nights…") }
                if let error { BiometricProfileError(error: error) }
                Button("Reload nights", systemImage: "arrow.clockwise") { Task { await load(cursor) } }.disabled(loading)
                if let page {
                    if page.items.isEmpty { Text("No recorded nights for this side.").foregroundStyle(Theme.text2) }
                    ForEach(page.items) { session in
                        VStack(alignment: .leading, spacing: 12) {
                            ReplaySessionSummary(session: session)
                            if draft.selectedSessions[session.id] != nil { Label("Selected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.text2) }
                            NavigationLink { ReplaySessionDetailScreen(client: client, draft: draft, session: session) } label: { Label("Inspect session \(session.id)", systemImage: "waveform.path.ecg") }.accessibilityIdentifier("datasets.session.\(session.id)")
                        }.cardStyle()
                    }
                    if cursor != nil { Button("Newest nights") { Task { await load(nil) } }.disabled(loading) }
                    if let next = page.nextCursor { Button("Older nights") { Task { await load(next) } }.disabled(loading) }
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Recorded nights").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("datasets.sessionsContent")
            .task { if page == nil { await load(nil) } }
    }
    private func load(_ next: ReplaySessionPage.Cursor?) async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await client.sessions(side: draft.side, cursor: next)
            guard !Task.isCancelled else { return }
            guard result.items.allSatisfy({ $0.side == draft.side && $0.id > 0 }) else { throw BiometricBacktestInput.error("The recorded nights do not match this side.") }
            page = result; cursor = next
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct ReplaySessionSummary: View {
    let session: ReplaySession
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session \(session.id)").font(.headline)
            BiometricProfileDate(title: "Entered bed", milliseconds: session.startMs)
            BiometricProfileDate(title: "Left bed", milliseconds: session.endMs)
            Text("\((session.sleepDurationSeconds / 3600).formatted(.number.precision(.fractionLength(1)))) hours asleep · Bed exits: \(session.timesExitedBed)").font(.footnote).foregroundStyle(Theme.text2)
        }
    }
}

struct ReplaySessionDetailScreen: View {
    let client: any BiometricDatasetsServing
    let draft: BiometricDatasetDraft
    let session: ReplaySession
    @State private var capabilities: ReplaySessionCapabilities?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ReplaySessionSummary(session: capabilities?.session ?? session).cardStyle()
                if let error { BiometricProfileError(error: error) }
                if loading { ProgressView("Inspecting retained readings…") }
                Button("Refresh inspection", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
                if let capabilities {
                    VStack(alignment: .leading, spacing: 12) {
                        BiometricProfileValue("Stored-reading comparison", value: capabilities.comparison ? "Available" : "No stored vitals")
                        BiometricProfileValue("Stage replay", value: capabilities.stageReplay ? "Available" : "Unavailable")
                        Text("Raw waveforms are not inventoried by this processed-data inspection.").font(.footnote).foregroundStyle(Theme.text2)
                        Text("Vitals with unknown processing provenance: \(capabilities.processed.legacyUnknownProvenanceCount)").font(.footnote)
                        if draft.selectedSessions[session.id] != nil {
                            Button("Remove this session", role: .destructive) { draft.removeSession(session.id) }.accessibilityIdentifier("datasets.removeSession")
                        } else {
                            Button("Include this session") { do { try draft.include(capabilities) } catch { self.error = error.localizedDescription } }
                                .disabled(!capabilities.comparison || draft.selectedSessions.count >= 60 || loading || error != nil).accessibilityIdentifier("datasets.includeSession")
                        }
                    }.cardStyle()
                    ReplayCoverageCard(title: "Stored vitals", coverage: capabilities.processed.vitals)
                    ReplayCoverageCard(title: "Movement records", coverage: capabilities.processed.movement)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Overlapping reference records").font(.headline)
                        Text("Counts include available revisions. Choose one revision per source family when freezing inputs.").font(.footnote).foregroundStyle(Theme.text2)
                        if capabilities.referenceMetrics.isEmpty { Text("No overlapping reference records.").foregroundStyle(Theme.text2) }
                        ForEach(capabilities.referenceMetrics, id: \.metric) { metric in BiometricProfileValue(ReferenceLabels.metric(metric.metric), value: String(metric.count)) }
                        ForEach(capabilities.limitations, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.text2) }
                    }.cardStyle()
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Session inspection").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("datasets.sessionContent")
            .task { if capabilities == nil { await load() } }
    }
    private func load() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await client.capabilities(side: draft.side, id: session.id)
            guard !Task.isCancelled else { return }
            guard result.session.id == session.id, result.session.side == draft.side else { throw BiometricBacktestInput.error("The session inspection has a different identity.") }
            capabilities = result
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct ReplayCoverageCard: View {
    let title: String
    let coverage: ReplayCoverage
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            BiometricProfileValue("Distinct timestamps", value: String(coverage.count))
            BiometricProfileValue("Duplicate timestamps", value: String(coverage.duplicateTimestamps))
            if let first = coverage.firstMs { BiometricProfileDate(title: "First record", milliseconds: first) }
            if let last = coverage.lastMs { BiometricProfileDate(title: "Last record", milliseconds: last) }
            BiometricProfileValue("Expected cadence", value: "\((coverage.expectedCadenceMs / 1000).formatted()) seconds")
            BiometricProfileValue("Gaps at this cadence", value: "\((coverage.gapDurationMs / 60000).formatted(.number.precision(.fractionLength(1)))) minutes")
            Text("Availability uses nominal recording cadence. It does not prove continuous signal support.").font(.footnote).foregroundStyle(Theme.text2)
            NavigationLink { ReplayCoverageGapsScreen(coverage: coverage) } label: { Label("Inspect \(coverage.gaps.count) exact gaps", systemImage: "list.bullet") }
        }.cardStyle()
    }
}
struct ReplayCoverageGapsScreen: View {
    let coverage: ReplayCoverage
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Exact UTC gap boundaries under the stated \((coverage.expectedCadenceMs / 1000).formatted())-second cadence. No missing readings are inferred.").font(.footnote).foregroundStyle(Theme.text2)
                if coverage.gaps.isEmpty { Text("No gaps at this recording cadence.") }
                ForEach(Array(coverage.gaps.enumerated()), id: \.offset) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        BiometricProfileValue("Start · UTC", value: ReferenceLabels.utc(item.element.startMs))
                        BiometricProfileValue("End · UTC", value: ReferenceLabels.utc(item.element.endMs))
                    }.cardStyle()
                }
            }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Recording gaps").navigationBarTitleDisplayMode(.inline)
    }
}
