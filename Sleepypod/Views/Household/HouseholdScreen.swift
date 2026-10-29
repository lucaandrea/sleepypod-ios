import SwiftUI

/// This root replaces the owner tabs; a personal credential never opens legacy controls.
struct HouseholdScreen: View {
    @Environment(HouseholdWorkspace.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation: [String] = []
    @State private var connectionForm: HouseholdConnectionForm.Kind?
    @State private var revealedCode: String?
    @State private var revokeDevice: HouseholdDevice?
    var body: some View {
        NavigationStack(path: $navigation) {
            Form {
                Section {
                    Label("Personal preparation", systemImage: "person.crop.circle").font(.headline)
                    Text("Prepare your own comfort preferences and weekly routine. Bed controls, side assignment, sleep history and Apple Health are not active in this workspace.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                    if let session = model.session {
                        Text(session.person.displayName).font(.title2.bold())
                        Text(session.assignmentLabel).accessibilityIdentifier("household.assignment")
                        Text("\(session.role.capitalized) account · \(model.selected?.endpoint.host ?? "Controller")")
                            .font(.caption).foregroundStyle(Theme.text2)
                    }
                }
                feedback
                if let session = model.session {
                    Section("Your private drafts") {
                        NavigationLink("Comfort preferences", value: "preferences")
                            .disabled(!model.maySave)
                        NavigationLink("Weekly routine drafts", value: "routines")
                            .disabled(!model.maySave)
                        Text("Draft only · nothing here schedules or moves the bed.").font(.footnote).foregroundStyle(Theme.amber)
                            .accessibilityIdentifier("household.draftOnly")
                    }
                    invitations(session)
                    Section("Your paired devices") {
                        ForEach(model.devices) { device in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    if device.current { Text("This device").font(.caption).foregroundStyle(Theme.text2) }
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) { revokeDevice = device }
                                    .disabled(!model.maySave || model.devices.count < 2)
                            }
                        }
                        Text("Pair another device before revoking your last one. Revoking a device removes its access to your personal account.").font(.footnote).foregroundStyle(Theme.text2)
                    }
                } else if model.pending == nil {
                    Section {
                        Button("Join with an invitation") { connectionForm = .join }
                            .accessibilityIdentifier("household.join")
                        if model.ownerSetupReady {
                            Button("Prepare my owner account") { connectionForm = .owner }
                                .accessibilityIdentifier("household.setup")
                        }
                    }
                }
                if !model.savedConnections.isEmpty {
                    Section("Personal connections on this device") {
                        ForEach(model.savedConnections) { record in
                            Button {
                                revealedCode = nil
                                Task { await model.select(record.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.identity?.person.displayName ?? "Unconfirmed connection")
                                    Text(record.endpoint.host ?? "Controller").font(.caption).foregroundStyle(Theme.text2)
                                }
                            }.disabled(model.busy)
                        }
                        Button("Close personal session") { revealedCode = nil; model.signOut() }.disabled(model.busy)
                        Text("Closing keeps this device paired. Use Revoke to remove its access.").font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
                if model.canReturnToOwner {
                    Section {
                        Button("Return to owner controls") { Task { await model.returnToOwner() } }.disabled(model.busy)
                        Text("Requires this device’s owner authentication. Your retained installation connection stays separate from personal accounts.")
                            .font(.footnote).foregroundStyle(Theme.text2)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Personal account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.busy || model.selected == nil)
            } }
            .navigationDestination(for: String.self) { route in
                if let session = model.session {
                    if route == "preferences" { HouseholdPreferencesEditor().id(session.namespace + String(model.preferences?.revision ?? 0)) }
                    else { HouseholdRoutineWeek().id(session.namespace + String(model.routines?.revision ?? 0)) }
                }
            }
            .sheet(item: $connectionForm) { kind in NavigationStack { HouseholdConnectionForm(kind: kind) } }
            .alert("Revoke device?", isPresented: Binding(get: { revokeDevice != nil }, set: { if !$0 { revokeDevice = nil } })) {
                Button("Revoke", role: .destructive) {
                    if let identifier = revokeDevice?.id { Task { await model.revoke(deviceId: identifier) } }
                    revokeDevice = nil
                }
                Button("Cancel", role: .cancel) { revokeDevice = nil }
            } message: { Text("\(revokeDevice?.name ?? "This device") will lose personal-account access. This does not change bed controls or schedules.") }
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { if scenePhase != .active { revealedCode = nil } }
        .onChange(of: model.session?.context) { revealedCode = nil; navigation = [] }
    }
    @ViewBuilder private var feedback: some View {
        if model.busy { Section { ProgressView("Updating personal account…") } }
        if let error = model.error { Section { Text(error).foregroundStyle(Theme.amber).accessibilityIdentifier("household.error") } }
        if let notice = model.notice { Section { Text(notice).font(.footnote).foregroundStyle(Theme.text2) } }
        if model.pending != nil {
            Section("Request awaiting confirmation") {
                Text("The original request is saved securely. Check the controller first; retrying sends exactly the same request and credential.").font(.footnote)
                Button("Check saved state") { Task { await model.refresh() } }.disabled(model.busy)
                Button("Retry same request") { Task { await model.retryPending() } }.disabled(model.busy)
            }
        }
        if model.needsDraftReview, model.preferences != nil, model.routines != nil, model.pending == nil {
            Section("Saved values changed") {
                Text("Another device changed these preferences or routines. Review the saved state before replacing it with your retained draft.").font(.footnote)
                Button("Use refreshed saved values") { model.reviewDrafts(keep: false) }
                Button("Keep my draft for review") { model.reviewDrafts(keep: true) }
            }
        }
    }
    private func invitations(_ session: HouseholdSession) -> some View {
        Section("Invitations") {
            if session.capabilities.manageInvitations {
                Button("Invite another person") { Task { await model.invite(kind: "new_person") } }.disabled(!model.maySave)
                Text("Joining prepares an unassigned account. It does not assign a side or activate a routine.").font(.footnote).foregroundStyle(Theme.text2)
            }
            Button("Pair my other device") { Task { await model.invite(kind: "own_device") } }.disabled(!model.maySave)
            ForEach(model.invitations) { invitation in
                VStack(alignment: .leading, spacing: 10) {
                    Text(invitation.kind == "new_person" ? "Another person" : "Your other device").font(.headline)
                    Text("\(invitation.status.capitalized) · Expires \(SensorObservation.date(invitation.expiresAt)?.formatted() ?? invitation.expiresAt)")
                        .font(.caption).foregroundStyle(Theme.text2)
                    if let code = model.invitationCode(invitation.id), let expiry = SensorObservation.date(invitation.expiresAt), expiry > .now {
                        if revealedCode == invitation.id {
                            Text(code).font(.caption.monospaced()).textSelection(.enabled).privacySensitive()
                            ShareLink("Share invitation", item: "Join my sleepypod personal workspace at \(model.selected?.endpoint.absoluteString ?? ""). Invitation: \(code)")
                            Button("Hide invitation") { revealedCode = nil }
                        } else { Button("Show invitation") { revealedCode = invitation.id } }
                        Button("Revoke invitation", role: .destructive) { Task { await model.revoke(invitationId: invitation.id) } }.disabled(!model.maySave)
                    }
                }.padding(.vertical, 4)
            }
        }
    }
}

struct HouseholdConnectionForm: View {
    enum Kind: String, Identifiable { case owner, join; var id: String { rawValue } }
    let kind: Kind
    @Environment(HouseholdWorkspace.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var deviceName = "My iPhone"
    @State private var invitation = ""
    @State private var sourceSide: Side = .left
    @State private var reviewed = false
    var body: some View {
        Form {
            Section {
                TextField("Controller address", text: $address).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(kind == .owner).accessibilityIdentifier("household.address")
                TextField("Your name", text: $name).textContentType(.givenName).accessibilityIdentifier("household.name")
                TextField("Device name", text: $deviceName).accessibilityIdentifier("household.deviceName")
                if kind == .join { SecureField("Invitation", text: $invitation).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("household.invitation") }
                else {
                    Picker("Current solo routine side", selection: $sourceSide) { Text("Left").tag(Side.left); Text("Right").tag(Side.right) }
                    Text("Confirms the side currently providing your solo routine. Personal drafts start separately; your active routine and bed operation stay unchanged.").font(.footnote)
                }
            }
            Section {
                Toggle(kind == .join ? "I understand this prepares an unassigned account" : "I understand these are personal drafts", isOn: $reviewed)
                Text("Routine drafts, side assignment, controls, sleep history and Health remain separate. Pairing another device with your own-device invitation keeps the same personal account.").font(.footnote).foregroundStyle(Theme.text2)
                Button(kind == .owner ? "Prepare account" : "Join account") {
                    Task {
                        await model.start(address: address, name: name, deviceName: deviceName, invitation: kind == .join ? invitation : nil, sourceSide: sourceSide)
                        invitation = ""
                        if model.pending != nil || model.session != nil { dismiss() }
                    }
                }.disabled(model.busy || !reviewed || name.trimmingCharacters(in: .whitespaces).isEmpty || address.isEmpty)
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            }
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(kind == .owner ? "Prepare account" : "Join account").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) } }
            .onAppear { if kind == .owner { address = OwnerConnection.displayAddress } }
            .interactiveDismissDisabled(model.busy)
    }
}
