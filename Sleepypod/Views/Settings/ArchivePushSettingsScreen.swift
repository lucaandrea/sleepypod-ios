import SwiftUI

struct ArchivePushSettingsScreen: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model = ArchivePushWorkspace(client: APIBackend.current.isDemo ? DemoArchivePushClient() : CoreArchivePushClient())
    @State private var confirmReload = false
    @State private var copied = false
    @FocusState private var focusedField: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if APIBackend.current.isDemo { Text("DEMO · changes affect simulated settings only").font(.footnote).foregroundStyle(Theme.amber) }
                if let snapshot = model.snapshot, let draft = model.draft {
                    destination(draft)
                    identity(snapshot)
                    testCard
                    NavigationLink { SystemDatabaseScreen() } label: { Label("Download a database backup", systemImage: "arrow.down.doc") }
                        .accessibilityIdentifier("archive.databaseBackup")
                    Text("Database downloads are separate from the nightly SSH archive. A successful connection test does not confirm archive delivery.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                } else if model.loading { ProgressView("Reading backup settings…") }
                if let operation = model.operation { ProgressView(operation) }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                if let receipt = model.receipt { Text(receipt).font(.footnote).accessibilityIdentifier("archive.receipt") }
                Button("Reload backup settings") {
                    if model.dirty { confirmReload = true } else { Task { await model.refresh(discardDraft: true) } }
                }.disabled(model.loading || model.busy).accessibilityIdentifier("archive.reload")
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Backup").accessibilityIdentifier("archive.content")
            .scrollDismissesKeyboard(.immediately)
            .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedField = nil }.accessibilityIdentifier("archive.keyboardDone") } }
            .task { if model.snapshot == nil { await model.refresh() } }
            .confirmationDialog("Discard unsaved backup changes?", isPresented: $confirmReload, titleVisibility: .visible) {
                Button("Reload settings", role: .destructive) { Task { await model.refresh(discardDraft: true) } }
                Button("Cancel", role: .cancel) {}
            }
    }
    private func destination(_ current: ArchivePushDraft) -> some View {
        let draft = Binding(get: { model.draft ?? current }, set: { model.draft = $0 })
        return VStack(alignment: .leading, spacing: 16) {
            Text("NIGHTLY ARCHIVE").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
            Text("Copy sensor archives and the biometrics database to storage you control over SSH, once per night.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            BridgeToggleRow(title: "Enable nightly push", value: draft.enabled, identifier: "archive.enabled")
            field("Host", identifier: "host", value: draft.host)
            field("Port", identifier: "port", value: draft.port, keyboard: .numberPad)
            field("Remote user", identifier: "user", value: draft.remoteUser)
            field("Remote path", identifier: "path", value: draft.remotePath)
            BridgeToggleRow(title: "RAW waveforms", value: draft.includeRaw, identifier: "archive.raw")
            BridgeToggleRow(title: "Biometrics database", value: draft.includeDatabase, identifier: "archive.database")
            if let issue = current.issue { Text(issue).font(.footnote).foregroundStyle(Theme.amber) }
            Button(typeSize.isAccessibilitySize ? "Save" : "Save backup configuration") { focusedField = nil; Task { await model.save() } }
                .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background)
                .disabled(!model.dirty || model.mustReload || current.issue != nil).accessibilityLabel("Save backup configuration").accessibilityIdentifier("archive.save")
        }.disabled(model.loading || model.busy).cardStyle()
    }
    private func identity(_ snapshot: ArchivePushSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SSH IDENTITY").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
            Text("Add this public key to the remote user’s ~/.ssh/authorized_keys. The private key stays on the Pod.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            if let key = snapshot.publicKey {
                Text(key).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("archive.publicKey")
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
                layout {
                    Button(copied ? "Copied" : "Copy public key") { UIPasteboard.general.string = key; copied = true }
                    if !typeSize.isAccessibilitySize { Spacer() }
                    ShareLink(item: key) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share public key")
                }
            } else {
                Button("Generate SSH keypair") { Task { await model.generateKey() } }
                    .disabled(model.busy || model.loading || model.mustReload || model.dirty).accessibilityIdentifier("archive.generateKey")
            }
            if model.dirty { Text("Save or discard edits before generating a key or testing the destination.").font(.footnote).foregroundStyle(Theme.text2) }
        }.cardStyle()
    }
    private var testCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CONNECTION TEST").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
            Text("Test the saved SSH destination without transferring an archive. The Pod may remember the server’s host key on first connection.")
                .font(.subheadline).foregroundStyle(Theme.text2)
            Button("Test saved destination") { Task { await model.testConnection() } }
                .disabled(model.busy || model.loading || model.mustReload || model.dirty).accessibilityIdentifier("archive.test")
            if let result = model.currentTest {
                Text(result.ok ? "Connection accepted" : "Connection failed").font(.headline).foregroundStyle(result.ok ? Theme.green : Theme.amber)
                Text(result.message).font(.footnote).textSelection(.enabled).accessibilityIdentifier("archive.testResult")
            }
        }.cardStyle()
    }
    private func field(_ title: String, identifier: String, value: Binding<String>, keyboard: UIKeyboardType = .asciiCapable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 4) {
                TextField(title, text: value).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    .keyboardType(keyboard).focused($focusedField, equals: identifier).accessibilityIdentifier("archive.\(identifier)")
                    .submitLabel(.done).onSubmit { focusedField = nil }
                if focusedField == identifier && !value.wrappedValue.isEmpty {
                    Button { value.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text2).frame(width: 44, height: 44)
                    }.accessibilityLabel("Clear \(title.lowercased())").accessibilityIdentifier("archive.clear.\(identifier)")
                }
            }
        }
    }
}
