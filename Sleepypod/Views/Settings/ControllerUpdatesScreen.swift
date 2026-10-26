import SwiftUI

struct ControllerUpdatesScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ControllerUpdateWorkspace?
    @State private var setupError: String?
    @State private var allowTemporaryInternet = false
    @State private var confirmStart = false
    @State private var confirmRestore = false
    @State private var confirmDismiss = false
    @State private var confirmUnreadable = false
    init() {
        do {
            guard APIBackend.current != .freeSleep else {
                throw APIError.serverError(message: "Native controller updates require Sleepypod Core. Use this controller’s existing installation tools to update it.")
            }
            let demo = APIBackend.current.isDemo
            let client: any ControllerUpdateServing = demo ? DemoControllerUpdateClient() : CoreControllerUpdateClient(transport: try .configured())
            _model = State(initialValue: .init(client: client, journal: demo ? .init(directory: nil) : try .persistent()))
        } catch { _setupError = State(initialValue: error.localizedDescription) }
    }
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if APIBackend.current.isDemo {
                        Text("DEMO · update and network states are simulated. No controller software changes.").font(.footnote).foregroundStyle(Theme.amber)
                    }
                    if let setupError { Text(setupError).foregroundStyle(Theme.amber) }
                    if let model {
                        if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true) }
                        if model.busy { ProgressView("Reading update state…") }
                        if model.storageError && model.attempt == nil {
                            Button("Remove unreadable local request record", role: .destructive) { confirmUnreadable = true }
                        }
                        if let attempt = model.attempt { attemptCard(attempt, model) }
                        else {
                            if let snapshot = model.snapshot { installed(snapshot.build) }
                            channelCard(model)
                            if let review = model.review { reviewCard(review, model).id("review") }
                        }
                        Button(model.attempt == nil ? "Refresh installed version" : "Check controller and network") { Task { await model.refresh() } }
                            .disabled(model.busy).accessibilityIdentifier("updates.refresh")
                    }
                    NavigationLink { SystemStorageScreen() } label: {
                        Label("Storage", systemImage: "internaldrive").frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    }
                    Text("Updates use the repository configured on your Pod. The controller does not report a download percentage or a remote latest-version check.")
                        .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: 780).padding(16).frame(maxWidth: .infinity)
            }.background(Theme.background)
                .onChange(of: model?.review) { _, value in
                    allowTemporaryInternet = false
                    if value != nil { withAnimation { scroll.scrollTo("review", anchor: .top) } }
                }
        }.navigationTitle("Updates").navigationBarTitleDisplayMode(.inline)
            .task(id: "\(scenePhase)-\(model?.attempt?.id.uuidString ?? "idle")") {
                guard scenePhase == .active, let model else { return }
                if model.attempt == nil { await model.refresh(); return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                repeat {
                    await model.observe()
                    guard model.shouldObserve else { return }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                } while !Task.isCancelled
            }
            .confirmationDialog("Start the reviewed controller update?", isPresented: $confirmStart, titleVisibility: .visible) {
                Button("Start update") { if let review = model?.review { Task { await model?.start(review, allowTemporaryInternet: allowTemporaryInternet) } } }
                    .accessibilityIdentifier("updates.confirmStart")
                Button("Cancel", role: .cancel) {}
            } message: { Text("The Pod service will restart. Keep power connected. A lost reply will not cause the app to repeat this request.") }
            .confirmationDialog("Restore local-only internet access?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Restore local only") { Task { await model?.restoreLocalOnly() } }.accessibilityIdentifier("updates.confirmRestore")
                Button("Cancel", role: .cancel) {}
            } message: { Text("This blocks external connections. If an update is still downloading, it may interrupt that download. The app checks current network state before changing it.") }
            .confirmationDialog("Remove the unreadable local record?", isPresented: $confirmUnreadable, titleVisibility: .visible) {
                Button("Remove local record", role: .destructive) { model?.discardUnreadableRecord() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This does not stop an update or restore networking. Check the controller before starting another update. A readable request is preserved.") }
            .confirmationDialog("Finish tracking this request?", isPresented: $confirmDismiss, titleVisibility: .visible) {
                Button("Finish tracking", role: .destructive) { model?.finishReview() }.accessibilityIdentifier("updates.confirmDismiss")
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes the app’s retained observation only. It cannot cancel the controller update or restore networking. An unconfirmed outcome remains unconfirmed.") }
    }
    private func installed(_ build: ControllerBuild) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Installed software").font(.headline)
            Text(build.version ?? "Version not reported").font(.title3)
            Text(build.branch).font(.subheadline)
            Text(build.commitTitle).font(.footnote).foregroundStyle(Theme.text2)
            BiometricProfileIdentity(title: "Commit", value: build.commitHash)
            Text("Built \(build.buildDate)").font(.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }.cardStyle()
    }
    private func channelCard(_ model: ControllerUpdateWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update channel").font(.headline)
            Picker("Update channel", selection: Binding(get: { model.channel }, set: { model.channel = $0 })) {
                Text("Choose a channel").tag(Optional<ControllerUpdateChannel>.none)
                ForEach(ControllerUpdateChannel.allCases) { Text($0.title).tag(Optional($0)) }
            }.pickerStyle(.menu).accessibilityIdentifier("updates.channel")
            Text("Development builds may contain unfinished changes. Review the installed build and internet state before starting.").font(.footnote).foregroundStyle(Theme.text2)
            Button("Review update") { Task { await model.prepareReview() } }.disabled(!model.canReview).accessibilityIdentifier("updates.review")
        }.cardStyle()
    }
    private func reviewCard(_ review: ControllerUpdateReview, _ model: ControllerUpdateWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review controller update").font(.headline)
            Text("Channel: \(review.channel.title)").font(.subheadline)
            BiometricProfileIdentity(title: "Installed commit", value: review.build.commitHash)
            Text(review.internetBlocked ? "The Pod is currently local only." : "The Pod currently allows internet access.").font(.footnote)
            if review.internetBlocked {
                Toggle("Allow temporary internet for this update", isOn: $allowTemporaryInternet).accessibilityIdentifier("updates.allowInternet")
                Text("The updater opens internet access for the download and restores its saved firewall afterward. The app will verify the reported network state when the controller responds.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            Button("Start reviewed update") { confirmStart = true }
                .disabled(model.busy || (review.internetBlocked && !allowTemporaryInternet)).accessibilityIdentifier("updates.start")
        }.cardStyle()
    }
    private func attemptCard(_ attempt: ControllerUpdateAttempt, _ model: ControllerUpdateWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(attempt.title).font(.headline).accessibilityIdentifier("updates.outcome")
            Text("Requested \(attempt.channel.title) · \(attempt.startedAt.formatted(date: .abbreviated, time: .shortened))").font(.footnote)
            if let receipt = attempt.receipt {
                Text("Request acknowledged by \(receipt.repository)").font(.subheadline)
                Text(receipt.message).font(.footnote).foregroundStyle(Theme.text2)
            }
            if let error = attempt.dispatchError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            if let error = attempt.lastReadError { Text("Latest controller read failed: \(error)").font(.footnote).foregroundStyle(Theme.amber) }
            if let build = attempt.lastBuild {
                BiometricProfileIdentity(title: "Last observed commit", value: build.commitHash)
                Text("Channel \(build.branch) · built \(build.buildDate)").font(.caption).foregroundStyle(Theme.text2)
            }
            Text("A request receipt is not completion. An unchanged build after reconnection does not establish that an update succeeded.").font(.footnote).foregroundStyle(Theme.text2)
            Divider()
            Text(attempt.networkBlocked.map { $0 ? "Network: local only" : "Network: internet allowed" } ?? "Network: not confirmed")
                .font(.subheadline).accessibilityIdentifier("updates.network")
            if let error = attempt.restoreError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            if attempt.internetWasBlocked && attempt.networkBlocked != true && attempt.outcome != .observing {
                Button("Restore local-only access") { confirmRestore = true }.disabled(model.busy).accessibilityIdentifier("updates.restore")
            }
            Button("Finish tracking this request") { confirmDismiss = true }.disabled(model.busy).accessibilityIdentifier("updates.dismiss")
        }.cardStyle()
    }
}
