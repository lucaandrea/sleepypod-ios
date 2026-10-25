import SwiftUI

struct PodConnectionCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage("podURL") private var savedAddress = ""
    @State private var setup: ConnectionSetup
    @State private var request: Task<Void, Never>?
    init(demo: Bool) {
        _setup = State(initialValue: ConnectionSetup(demo: demo) {
            let address = UserDefaults.standard.string(forKey: "podURL") ?? ""
            return .init(address: address, token: TokenStore.read(for: address))
        })
    }
    var body: some View {
        SleepCard(title: "Your Pod connection", eyebrow: "LOCAL FIRST") {
            Text("Connect at home or through your secure gateway. Check the connection before saving.").foregroundStyle(SleepTheme.secondary)
            SleepFormField(title: "Pod or secure gateway address") {
                TextField("http://free-sleep.local:3000", text: $setup.address).keyboardType(.URL).textContentType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.plain)
                    .accessibilityLabel("Pod or secure gateway address")
            }.disabled(setup.testing)
            Text("Enter your Pod or gateway address. Changing the address clears the token field.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            SleepFormField(title: "Connection token") {
                SecureField("Connection token", text: $setup.token).textFieldStyle(.plain).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().accessibilityLabel("Connection token")
            }.disabled(setup.testing)
            Text("Your token stays in this iPhone's Keychain. Cloud model keys belong on your server.").sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            Button(setup.testing ? "Testing connection…" : "Test connection") {
                request = Task {
                    await setup.check { input in
                        let settings: PodSettings = try await PodClient(address: input.address, token: input.token).get("settings")
                        return try ConnectionIdentity(settings: settings)
                    }
                }
            }.buttonStyle(SleepButtonStyle(fill: true)).disabled(setup.testing)
            Button("Save connection") {
                setup.save { input in
                    try TokenStore.save(input.token, for: input.address)
                    savedAddress = input.address; model.connectionChanged()
                    Task { await model.refresh() }
                }
            }.buttonStyle(SleepButtonStyle(kind: .primary, fill: true)).disabled(setup.testing)
            if let result = setup.result {
                Text("\(setup.demo ? "Demo connection verified" : "Connection verified") · \(result.id) · \(result.timeZone)")
                    .sleepText(.small).foregroundStyle(SleepTheme.success)
            }
            if let failure = setup.failure { Text(failure).sleepText(.small).foregroundStyle(SleepTheme.error) }
            if let message = setup.message { Text(message).sleepText(.small).foregroundStyle(SleepTheme.success) }
        }.onDisappear { request?.cancel(); setup.invalidate() }
    }
}
