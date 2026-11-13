import SwiftUI

struct PersonalRouteScreen: View {
    private enum Field: Hashable { case home, away }
    @Environment(HouseholdWorkspace.self) private var household
    @FocusState private var focusedField: Field?
    @State private var home = ""
    @State private var away = ""
    @State private var reviewed = false
    var body: some View {
        Form {
            Section {
                Label("One account, at home and away", systemImage: "house.and.flag").font(.headline)
                Text("Save your home address and secure remote address once. Sleepypod checks that both reach your Pod and personal account before using them automatically.")
                Text("A remote address needs a working HTTPS gateway or private VPN connection. Saving an address does not create that connection.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            if let profile = household.selected?.verifiedRoutes {
                Section("Saved connections") {
                    LabeledContent("Home", value: profile.home.absoluteString)
                    LabeledContent("Away", value: profile.away.absoluteString)
                    LabeledContent("Using", value: household.selected?.endpoint == profile.home ? "Home" : "Away")
                    Toggle("Recover automatically", isOn: Binding(get: { household.selected?.verifiedRoutes?.enabled == true },
                        set: { household.setPersonalRoutesEnabled($0) }))
                        .disabled(!household.mayEditPersonalRoutes).accessibilityIdentifier("personalRoutes.enabled")
                }
            }
            Section("Verify your addresses") {
                TextField("Home address", text: $home).accessibilityIdentifier("personalRoutes.home")
                    .keyboardType(.URL).focused($focusedField, equals: .home).submitLabel(.next)
                    .onSubmit { focusedField = .away }
                TextField("Away address (HTTPS)", text: $away).accessibilityIdentifier("personalRoutes.away")
                    .keyboardType(.URL).focused($focusedField, equals: .away).submitLabel(.done)
                    .onSubmit { focusedField = nil }
                Toggle("These addresses belong to my Pod", isOn: $reviewed).accessibilityIdentifier("personalRoutes.reviewed")
                Text("Verification sends this device’s personal connection key to both addresses. Use only the addresses set up for your Pod.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                Button { Task { await household.enrollPersonalRoutes(home: home, away: away) } } label: {
                    if household.routes.busy { ProgressView("Checking both connections…") }
                    else { Text("Verify and save") }
                }
                .disabled(!reviewed || home.isEmpty || away.isEmpty || !household.mayEditPersonalRoutes)
                .accessibilityIdentifier("personalRoutes.verify")
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            if let message = household.routes.message {
                Section { Text(message).accessibilityIdentifier("personalRoutes.message") }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Home and away").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedField = nil } } }
        .task {
            household.routes.editing = true
            home = household.selected?.verifiedRoutes?.home.absoluteString ?? household.selected?.endpoint.absoluteString ?? ""
            away = household.selected?.verifiedRoutes?.away.absoluteString ?? ""
        }
        .onChange(of: home) { reviewed = false }
        .onChange(of: away) { reviewed = false }
        .onDisappear { household.routes.editing = false; household.routes.invalidate() }
    }
}
