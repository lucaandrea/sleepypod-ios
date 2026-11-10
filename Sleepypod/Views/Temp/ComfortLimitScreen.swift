import SwiftUI

struct ComfortLimitScreen: View {
    let side: Side
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ownerConnectionRevision") private var ownerRevision = ""
    @AppStorage("household.boundaryRevision") private var householdRevision = ""
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("podIPAddress") private var address = ""
    private var scope: [String] { [backend, endpoint, address, ownerRevision, householdRevision] }
    @State private var model = ComfortLimitWorkspace()
    @State private var draft: Draft?
    @State private var refreshRevision = 0
    @State private var practice = DemoComfortLimitClient()

    private struct Draft {
        let original: ComfortLimitPage
        var config: ComfortLimitConfiguration
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if APIBackend.current.isDemo { Text("DEMO · practice only. This range does not change a Pod.").font(.caption).foregroundStyle(Theme.amber) }
                Label("Overnight comfort limit", systemImage: "checkmark.shield").font(.title2.bold())
                Text("\(side.rawValue.capitalized) zone").font(.subheadline).foregroundStyle(Theme.text2)
                if let page = model.page {
                    overview(page)
                    if let draft {
                        editor(draft)
                    } else {
                        Button("Edit comfort range") { draft = .init(original: page, config: page.config) }
                            .buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background).accessibilityIdentifier("comfort.limit.edit")
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(Theme.amber).font(.footnote) }
                Button(model.busy ? "Checking…" : "Refresh", systemImage: "arrow.clockwise") { refreshRevision += 1 }
                    .disabled(model.busy).frame(minHeight: 44)
            }.padding(20).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Comfort limit").navigationBarTitleDisplayMode(.inline)
            .task(id: scope + [side.rawValue, String(describing: scenePhase), String(refreshRevision)]) {
                model.invalidate(); draft = nil
                guard scenePhase == .active else { return }
                let transport = APIBackend.current == .sleepypodCore ? try? CoreRESTClient.configured() : nil
                let client: (any ComfortLimitClient)? = APIBackend.current.isDemo ? practice : transport.map { CoreComfortLimitClient(transport: $0) }
                model.configure(side: side, client: client)
                await model.refresh()
            }
            .onDisappear { model.invalidate(); draft = nil }
    }
    private func overview(_ page: ComfortLimitPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(page.config.enabled ? "\(page.config.minF)–\(page.config.maxF)°F automatic range" : "No automatic range enabled").font(.headline)
            Text(page.config.enabled ? "Schedules, Autopilot and run-once plans stay within this range whenever the bed is on. Manual temperature holds temporarily override it." : "Enable a range to bound automatic schedules, Autopilot and run-once plans independently of personal learning.").font(.subheadline)
            if page.sourceSide != side { Text("This zone follows the \(page.sourceSide.rawValue) sleeper’s range.").font(.subheadline) }
            if let wake = page.wake {
                Text("Next wake warming may leave the range at \(wakeClock(wake)), toward \(wake.targetF.formatted())°F. The range resumes after the alarm’s warm hold.").font(.subheadline).foregroundStyle(Theme.amber)
            } else {
                Text(page.wakeAvailable ? "No next wake-warming exception is scheduled." : "Next wake time is unavailable. Refresh to confirm it.").font(.subheadline).foregroundStyle(Theme.text2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
    private func editor(_ current: Draft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable automatic comfort range", isOn: Binding(get: { draft?.config.enabled ?? false }, set: { draft?.config.enabled = $0 }))
            Stepper("Minimum: \(current.config.minF)°F", value: Binding(get: { draft?.config.minF ?? 68 }, set: { draft?.config.minF = $0 }), in: 55...110)
            Stepper("Maximum: \(current.config.maxF)°F", value: Binding(get: { draft?.config.maxF ?? 72 }, set: { draft?.config.maxF = $0 }), in: 55...110)
            Text("Choose a range up to 10°F wide. Saving applies it to automatic targets on a powered side; it does not turn the bed on or enable personal learning.").font(.footnote).foregroundStyle(Theme.text2)
            if !current.config.isValid { Text("Minimum must not exceed maximum, and the range must be no wider than 10°F.").font(.footnote).foregroundStyle(Theme.amber) }
            Button("Save comfort range") {
                Task { if await model.save(current.config, original: current.original) { draft = nil } }
            }.buttonStyle(.borderedProminent).tint(Theme.text1).foregroundStyle(Theme.background).disabled(!current.config.isValid).accessibilityIdentifier("comfort.limit.save")
            Button("Cancel", role: .cancel) { draft = nil }.frame(minHeight: 44)
        }.disabled(model.busy).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
    private func wakeClock(_ wake: ComfortLimitPage.Wake) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: wake.timeZone)
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: wake.startsDate)
    }
}
