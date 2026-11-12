import SwiftUI
import FreeSleepKit

struct TemporaryCoolingPanel: View {
    let side: Side
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var workspace = TemporaryCoolingWorkspace()
    @State private var preview: TemporaryCooling.Proposal?
    #if DEBUG
    @State private var testExample: TemporaryCoolingExample?
    #endif
    private var scope: [String] { OwnerConnection.revision + [side.rawValue, String(describing: scenePhase)] }
    private var format: TemperatureFormat { settings.temperatureFormat == .relative ? .fahrenheit : settings.temperatureFormat }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            // A network reply can arrive after the last timeline tick. Validate against the
            // render clock so a fresh active lease does not briefly become an unavailable preview.
            let now = Date.now
            let report = workspace.report.flatMap { $0.current(at: now) ? $0 : nil }
            let pendingPreview: TemporaryCooling.Proposal? = {
                if case let .starting(proposal) = workspace.operation { return proposal }
                return nil
            }()
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                Text("A little cooler, for now").font(.headline)
                Text("\(side.displayName) zone · \(settings.sideName(for: side)). Only this zone changes, even when sides are linked.")
                    .font(.subheadline).foregroundStyle(Theme.text2)
                if let lease = report?.lease {
                    Text(report?.state == "cooling"
                         ? "Requested \(temperature(lease.targetF)) · return due \(clock(lease.expiresAt))"
                         : "Return not confirmed · inspect the current target.")
                        .font(.subheadline).accessibilityIdentifier("cooling.active")
                    Button("Cancel temporary cooling") { Task { await workspace.cancel() } }
                        .buttonStyle(.bordered).disabled(workspace.busy || (workspace.attempt?.needsReview == true && workspace.attempt?.request.action.kind == "cooling.cancel"))
                        .frame(minHeight: 44).accessibilityIdentifier("cooling.cancel")
                } else if preview == nil && pendingPreview == nil {
                    Button("I’m too hot", systemImage: "snowflake") { preview = report?.proposal }
                        .buttonStyle(.bordered).frame(minHeight: 44).accessibilityIdentifier("cooling.preview")
                        .disabled(workspace.busy || report?.state != "ready" || report?.proposal == nil || workspace.attempt?.needsReview == true)
                }
                if let reason = report?.reason {
                    Text(reason).font(.footnote).foregroundStyle(Theme.text2)
                } else if workspace.operation == nil {
                    Text("Temporary cooling is unavailable. Reconnect to an updated Pod and check again.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }
                if let preview = pendingPreview ?? preview {
                    Text("Request \(temperature(preview.targetF)) instead of \(temperature(preview.fromTargetF)), until no later than \(clock(preview.expiresAt)). This records ‘too hot’ as feedback and pauses personal adaptation. Your wake schedule is unchanged.")
                        .font(.subheadline).accessibilityIdentifier("cooling.review")
                    if pendingPreview == nil && report?.matches(preview, at: now) != true {
                        Text("The proposal changed or expired. Refresh and review it again.").font(.footnote).foregroundStyle(Theme.text2)
                    }
                    if pendingPreview == nil {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { reviewActions(preview, report: report, now: now) }
                            VStack(alignment: .leading, spacing: 8) { reviewActions(preview, report: report, now: now) }
                        }
                    }
                }
                if let operation = workspace.operation {
                    HStack(alignment: .top, spacing: 8) {
                        ProgressView().accessibilityHidden(true)
                        Text(operation.title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("cooling.progress")
                    }
                }
                if let notice = workspace.notice {
                    Text(notice).font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("cooling.notice")
                }
                #if DEBUG
                if APIBackend.current.isDemo, UserDefaults.standard.bool(forKey: "uiCoolingDelayed"),
                   testExample != nil, workspace.busy {
                    Button("Complete simulated reply") { Task { await testExample?.completeReply() } }
                        .frame(minHeight: 44).accessibilityIdentifier("cooling.example.reply")
                }
                #endif
                if workspace.attempt?.needsReview == true {
                    Button("Check last request") { Task { await workspace.checkRequest() } }
                        .disabled(workspace.busy).frame(minHeight: 44).accessibilityIdentifier("cooling.check")
                    NavigationLink("Open Command history") { NativeCommandHistoryScreen() }.frame(minHeight: 44)
                }
                Button("Refresh cooling state", systemImage: "arrow.clockwise") {
                    preview = nil
                    Task { await workspace.refresh() }
                }.disabled(workspace.busy).frame(minHeight: 44).accessibilityIdentifier("cooling.refresh")
                Divider()
            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: scope) {
            workspace.invalidate(); preview = nil
            guard scenePhase == .active, !PersonalWorkspaceBoundary.isActive else { return }
            configure()
            repeat {
                await workspace.refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            } while !Task.isCancelled
        }
        .onDisappear { workspace.invalidate(); preview = nil }
    }
    @ViewBuilder private func reviewActions(_ proposal: TemporaryCooling.Proposal, report: TemporaryCooling?, now: Date) -> some View {
        Button("Start temporary cooling") {
            preview = nil
            Task { await workspace.start(proposal) }
        }.buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
            .frame(minHeight: 44).accessibilityIdentifier("cooling.start")
            .disabled(workspace.busy || report?.matches(proposal, at: now) != true || workspace.attempt?.needsReview == true)
        Button("Not now") { preview = nil }.frame(minHeight: 44).accessibilityIdentifier("cooling.dismiss")
    }
    private func temperature(_ value: Int) -> String { TemperatureConversion.displayTemp(value, format: format) }
    private func clock(_ value: Int64) -> String {
        TemporaryCooling.date(value).formatted(Date.FormatStyle(date: .omitted, time: .shortened,
            timeZone: TimeZone(identifier: settings.timeZone) ?? .current))
    }
    private func configure() {
        #if DEBUG
        if APIBackend.current.isDemo, UserDefaults.standard.bool(forKey: "uiCoolingExample") {
            let example = TemporaryCoolingExample(unconfirmed: UserDefaults.standard.bool(forKey: "uiCoolingLost"), delayed: UserDefaults.standard.bool(forKey: "uiCoolingDelayed"))
            testExample = example
            let controls = NativeControlService(ledger: .init(directory: nil), client: { example }, live: { APIBackend.current.isDemo })
            workspace.configure(side: side, client: example, controls: controls)
            return
        }
        #endif
        guard APIBackend.current == .sleepypodCore, let transport = try? CoreRESTClient.configured(),
              let ledger = try? NativeControlLedger.persistent() else {
            workspace.configure(side: side, client: nil, controls: nil)
            return
        }
        let controls = NativeControlService(ledger: ledger, client: { CoreNativeControlClient(transport: transport) })
        workspace.configure(side: side, client: CoreTemporaryCoolingClient(transport: transport), controls: controls)
    }
}
