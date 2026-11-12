import SwiftUI

struct HouseholdConnectionForm: View {
    enum Kind: String, Identifiable { case owner, join; var id: String { rawValue } }
    let kind: Kind
    @Environment(HouseholdWorkspace.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var address = ""
    @State private var name = ""
    @State private var deviceName = UIDevice.current.userInterfaceIdiom == .pad ? "My iPad" : "My iPhone"
    @State private var invitation = ""
    @State private var sourceSide: Side = .left
    @State private var reviewed = false
    @State private var manual = false
    @State private var link = HouseholdInvitationDraft()
    private enum Field: Hashable { case link, address, code, name, device }
    @FocusState private var focusedField: Field?
    private var destination: URL? {
        kind == .join && !manual ? link.reviewed?.endpoint : try? HouseholdHTTPClient.endpoint(address)
    }
    private var invitationSecret: String? { kind == .owner ? nil : manual ? invitation : link.reviewed?.invitation }
    private var canJoin: Bool {
        !model.busy && reviewed && destination != nil
            && HouseholdValidation.name(name.trimmingCharacters(in: .whitespacesAndNewlines))
            && HouseholdValidation.name(deviceName.trimmingCharacters(in: .whitespacesAndNewlines))
            && (kind == .owner || invitationSecret.map(HouseholdValidation.secret) == true)
    }
    var body: some View {
        Form {
            if kind == .join { invitationEntry }
            Section("About you") {
                if kind == .owner {
                    TextField("Controller address", text: $address).disabled(true).accessibilityIdentifier("household.address")
                }
                TextField("Your name", text: $name, prompt: fieldPrompt("Your name"))
                    .textContentType(.givenName).focused($focusedField, equals: .name).accessibilityIdentifier("household.name")
                TextField("Device name", text: $deviceName, prompt: fieldPrompt("Device name"))
                    .focused($focusedField, equals: .device).accessibilityIdentifier("household.deviceName")
                if kind == .owner {
                    Picker("Current solo routine side", selection: $sourceSide) { Text("Left").tag(Side.left); Text("Right").tag(Side.right) }
                    Text("Confirms the side currently providing your solo routine. Personal drafts start separately; your active routine and bed operation stay unchanged.").font(.footnote)
                }
            }
            Section {
                Toggle(kind == .join ? "I understand joining does not change bed sides or routines" : "I understand these are personal drafts", isOn: $reviewed)
                    .accessibilityIdentifier("household.joinAcknowledgment")
                Text("Routine drafts, side assignment, controls, sleep history and Health remain separate. Pairing another device with your own-device invitation keeps the same personal account.")
                    .font(.footnote).foregroundStyle(Theme.text1)
                Button(model.busy ? "Connecting…" : kind == .owner ? "Prepare account" : "Join account", action: join)
                    .disabled(!canJoin).accessibilityIdentifier("household.joinSubmit")
                if let error = model.error { errorMessage(error, identifier: "household.joinError") }
            }
        }.scrollContentBackground(.hidden).background(Theme.background).accessibilityIdentifier("household.joinForm")
            .scrollDismissesKeyboard(.interactively).submitLabel(.done).onSubmit { focusedField = nil }
            .navigationTitle(kind == .owner ? "Prepare account" : "Join account").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }.accessibilityIdentifier("household.keyboardDone")
                }
            }
            .onAppear { if kind == .owner { address = OwnerConnection.displayAddress } }
            .onChange(of: manual) { clearInvitation() }
            .onChange(of: scenePhase) { if scenePhase != .active { clearInvitation() } }
            .onDisappear { clearInvitation() }
            .interactiveDismissDisabled(model.busy)
            .disabled(model.busy)
    }
    private var invitationEntry: some View {
        Section {
            Label("Your personal invitation", systemImage: "envelope.open").font(.headline)
            Text("Paste the complete invitation link your partner sent. You do not need an address or owner key.")
                .font(.footnote).foregroundStyle(Theme.text1)
            if manual {
                TextField("Controller address", text: $address, prompt: fieldPrompt("Controller address"))
                    .textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focusedField, equals: .address)
                    .accessibilityIdentifier("household.address").onChange(of: address) { reviewed = false }
                SecureField("Invitation code", text: $invitation, prompt: fieldPrompt("Invitation code"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focusedField, equals: .code)
                    .privacySensitive().accessibilityIdentifier("household.invitation").onChange(of: invitation) { reviewed = false }
                if let destination { destinationReview(destination) }
            } else {
                SecureField("Personal invitation link", text: Binding(get: { link.text }, set: { link.edit($0); reviewed = false }),
                            prompt: fieldPrompt("Personal invitation link"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).privacySensitive()
                    .focused($focusedField, equals: .link).accessibilityIdentifier("household.invitationLink")
                PasteButton(payloadType: String.self) { values in
                    if let first = values.first { link.edit(first); reviewed = false }
                }.accessibilityLabel("Paste invitation link").accessibilityIdentifier("household.pasteInvitation")
                Button("Review invitation") { focusedField = nil; link.review() }
                    .disabled(link.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("household.reviewInvitation")
                if let candidate = link.reviewed { destinationReview(candidate.endpoint) }
                if let error = link.error { errorMessage(error, identifier: "household.invitationError") }
            }
            Toggle("Use separate address and code", isOn: $manual).font(.footnote).accessibilityIdentifier("household.manualInvitation")
        } footer: {
            Text("Invitation codes are single-use and expire. An expired or used invitation needs a new link from the sender. Unsubmitted links are cleared when this screen is hidden.")
        }
    }
    private func fieldPrompt(_ title: String) -> Text { Text(title).foregroundStyle(Theme.text1) }
    private func errorMessage(_ message: String, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.amber).accessibilityHidden(true)
            Text(message).foregroundStyle(Theme.text1).accessibilityIdentifier(identifier)
        }.font(.footnote)
    }
    private func destinationReview(_ endpoint: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Join this controller").font(.headline)
            Text(endpoint.absoluteString).textSelection(.enabled).accessibilityIdentifier("household.invitationOrigin")
            Text("Check this is the controller your sender intended. Your invitation is sent only when you tap Join account.")
                .font(.footnote).foregroundStyle(Theme.text1)
            if endpoint.scheme == "http" {
                Text("Home-network address: connect to the same trusted Wi-Fi before joining.")
                    .font(.footnote).foregroundStyle(Theme.text1)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func clearInvitation() { link.clear(); invitation = ""; reviewed = false; if kind == .join { address = "" } }
    private func join() {
        guard canJoin, let destination else { return }
        let secret = invitationSecret
        Task {
            await model.start(address: destination.absoluteString, name: name, deviceName: deviceName, invitation: secret, sourceSide: sourceSide)
            clearInvitation()
            if model.pending != nil || model.session != nil { dismiss() }
        }
    }
}
