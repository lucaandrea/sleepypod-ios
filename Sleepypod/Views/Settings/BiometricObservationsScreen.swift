import SwiftUI

struct BiometricObservationsScreen: View {
    let side: Side
    let client: any BiometricObservationsServing
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: BiometricObservationsWorkspace?
    @State private var error: String?
    var body: some View {
        BiometricReportPage(title: "Prospective observations") {
            ReferenceSideValue(side: side)
            Text("Compare a candidate alongside active processing. Observations do not change your active profile.").font(.footnote).foregroundStyle(Theme.text2)
            if APIBackend.current.isDemo { Text("Demo · scheduling is kept in memory. Example reports use synthetic readings; no hardware processing or qualification is represented.").font(.footnote).foregroundStyle(Theme.text2) }
            if let error { BiometricProfileError(error: error) }
            if let model {
                NavigationLink { BiometricObservationScheduleScreen(model: model) } label: { SettingsRow("Schedule an observation", icon: "calendar.badge.plus", tile: true, chevron: true) }.cardStyle().accessibilityIdentifier("observations.schedule")
                BiometricObservationPendingCard(model: model)
                Button("Refresh observations", systemImage: "arrow.clockwise") { Task { await model.loadList(afterId: model.afterId) } }.disabled(model.loading)
                if let error = model.listError { BiometricProfileError(error: error) }
                if let page = model.page {
                    if page.items.isEmpty { Text("No prospective runs for this side.").foregroundStyle(Theme.text2).accessibilityIdentifier("observations.empty") }
                    ForEach(page.items) { run in
                        NavigationLink { BiometricObservationDetailScreen(model: model, run: run) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(run.state.title).font(.headline)
                                Text(run.subjectId).foregroundStyle(Theme.text2)
                                Text(ReferenceLabels.utc(run.startMs)).font(.footnote.monospaced()).foregroundStyle(Theme.text2)
                            }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                        }.accessibilityIdentifier("observations.run.\(run.id)")
                    }
                    if model.afterId != nil { Button("First page") { Task { await model.loadList() } }.disabled(model.loading) }
                    if let next = page.nextCursor { Button("Next page") { Task { await model.loadList(afterId: next) } }.disabled(model.loading) }
                } else if model.loading { ProgressView("Loading observations…") }
            } else if error == nil { ProgressView("Loading observations…") }
        }.task {
            guard model == nil else { return }
            do {
                let store = APIBackend.current.isDemo ? BiometricObservationPendingStore(directory: nil) : try .persistent()
                model = BiometricObservationsWorkspace(side: side, client: client, pendingStore: store)
            } catch { self.error = error.localizedDescription }
        }.task(id: "\(scenePhase)-\(model != nil)") {
            guard scenePhase == .active, let model else { return }
            while !Task.isCancelled {
                await model.loadList(afterId: model.afterId)
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}
struct BiometricObservationPendingCard: View {
    let model: BiometricObservationsWorkspace
    @State private var confirmDiscard = false
    var body: some View {
        if model.hasPending || model.mutationError != nil || model.notice != nil {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.mutationError { BiometricProfileError(error: error) }
                if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
                if let pending = model.pending {
                    Text("Retained observation request").font(.headline)
                    Text("Retry preserves the exact plan or stop request. Opening this screen does not send it.").font(.footnote).foregroundStyle(Theme.text2)
                    DisclosureGroup("Request identity") {
                        switch pending {
                        case .create(let request):
                            BiometricProfileIdentity(title: "Plan hash", value: request.prepared.planHash)
                            BiometricProfileIdentity(title: "Request identity", value: request.idempotencyKey)
                        case .stop(let run):
                            BiometricProfileIdentity(title: "Run", value: run.id)
                            BiometricProfileIdentity(title: "Plan hash", value: run.planHash)
                        }
                    }
                    Button("Retry exact request") { Task { await model.retry() } }.disabled(model.busy).accessibilityIdentifier("observations.retry")
                }
                if model.hasPending { Button("Remove retained retry", role: .destructive) { confirmDiscard = true }.disabled(model.busy) }
            }.cardStyle().confirmationDialog("Remove this retry? This does not stop or undo a saved observation.", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Remove retained retry", role: .destructive) { Task { await model.discardRetry() } }
            }
        }
    }
}
struct BiometricObservationDetailScreen: View {
    let model: BiometricObservationsWorkspace
    @State private var details: BiometricObservationDetailsWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmStop = false
    init(model: BiometricObservationsWorkspace, run: BiometricObservationRun) {
        self.model = model; _details = State(initialValue: .init(run: run, client: model.client))
    }
    var body: some View {
        BiometricReportPage(title: "Observation details") {
            ReferenceSideValue(side: details.run.side)
            Text(details.run.state.title).font(.title2).accessibilityIdentifier("observations.state")
            if let error = details.error { BiometricProfileError(error: error) }
            Button("Refresh observation", systemImage: "arrow.clockwise") { Task { await details.refresh() } }.disabled(details.reading)
            VStack(alignment: .leading, spacing: 12) {
                BiometricProfileValue("Sleeper identity", value: details.run.subjectId)
                BiometricProfileValue("Start · UTC", value: ReferenceLabels.utc(details.run.startMs))
                BiometricProfileValue("End · UTC", value: ReferenceLabels.utc(details.run.endMs))
                BiometricProfileValue("Saved observations", value: String(details.run.pointCount))
                BiometricProfileValue("Saved bytes", value: String(details.run.byteCount))
                if let reason = details.run.reason { Text(ReportDisplay.label(reason)).font(.footnote).foregroundStyle(Theme.text2) }
                if details.run.state == .pending { Text("Waiting for the scheduled window and fresh resource admission. No observations are implied yet.").font(.footnote).foregroundStyle(Theme.text2) }
                if details.run.state == .stopped { Text("Stop recorded. Saved observations are preserved.").font(.footnote).foregroundStyle(Theme.text2) }
                if !details.run.candidateIdentitySaved { Text("This older run has no saved candidate revision identity.").font(.footnote).foregroundStyle(Theme.text2) }
            }.cardStyle()
            if details.run.state.isActive {
                Button("Stop observation", role: .destructive) { confirmStop = true }.disabled(!model.canEdit || details.reading || details.error != nil).accessibilityIdentifier("observations.stop")
            }
            NavigationLink { BiometricObservationReportScreen(details: details) } label: { SettingsRow("Review observation report", icon: "chart.xyaxis.line", tile: true, chevron: true) }.cardStyle().accessibilityIdentifier("observations.report")
            DisclosureGroup("Saved evidence identity") {
                VStack(alignment: .leading, spacing: 10) {
                    BiometricProfileIdentity(title: "Run", value: details.run.id)
                    BiometricProfileIdentity(title: "Candidate hash", value: details.run.candidateConfigHash)
                    BiometricProfileIdentity(title: "Active profile hash", value: details.run.activeConfigHash)
                    BiometricProfileIdentity(title: "Plan hash", value: details.run.planHash)
                }.padding(.top, 8)
            }.cardStyle()
            BiometricObservationPendingCard(model: model)
        }.task(id: scenePhase) {
            guard scenePhase == .active else { return }
            repeat {
                await details.refresh()
                guard details.run.state.isActive else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }.onChange(of: model.savedRun) { _, receipt in if let receipt { details.accept(receipt) } }
            .confirmationDialog("Stop this observation? Saved observations will remain available.", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop observation", role: .destructive) { Task { await model.stop(details.run) } }.accessibilityIdentifier("observations.confirmStop")
            }
    }
}
