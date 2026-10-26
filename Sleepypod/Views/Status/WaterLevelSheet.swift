import SwiftUI

struct WaterLevelSheet: View {
    let currentLevel: String
    @Environment(\.dismiss) private var dismiss
    @Environment(DeviceManager.self) private var device
    @State private var confirmPrime = false
    @State private var sending = false
    @State private var requiresRefresh = false
    @State private var primeResult: String?
    private var level: String { (device.deviceStatus?.waterLevel ?? currentLevel).lowercased() }
    private var isLow: Bool { ["false", "low", "empty"].contains(level) }
    private var isKnownGood: Bool { ["true", "full", "good", "ok"].contains(level) }
    private var fresh: Bool {
        guard device.isConnected, let received = device.lastUpdated else { return false }
        return (0...30).contains(Date.now.timeIntervalSince(received))
    }
    private var priming: Bool { device.deviceStatus?.isPriming == true }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(fresh ? waterDescription : "Current water level is unavailable", systemImage: isLow ? "drop.triangle.fill" : "drop.fill")
                        .foregroundStyle(!fresh || !isKnownGood ? Theme.amber : Theme.green)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Priming").font(.headline)
                        Text("Priming circulates water through the tubing to remove trapped air. Refill the tank according to your Pod’s maintenance instructions before starting.")
                            .font(.subheadline).foregroundStyle(Theme.text2)
                        if priming { PrimingIndicator() }
                        if let primeResult { Text(primeResult).font(.footnote).foregroundStyle(Theme.text2) }
                        Button("Refresh controller status") {
                            Task {
                                await device.fetchStatus()
                                if fresh { requiresRefresh = false }
                            }
                        }.disabled(sending)
                    }.cardStyle()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Water care").font(.headline)
                        Text("Follow the instructions for your Pod model. Pod 4 and Pod 5 have a replaceable maintenance insert; older Pods use different maintenance procedures.")
                            .font(.subheadline).foregroundStyle(Theme.text2)
                        Link("Eight Sleep maintenance-insert instructions", destination: URL(string: "https://www.eightsleep.com/product/pod-maintenance-insert")!)
                            .font(.subheadline)
                    }.cardStyle()
                }.padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    confirmPrime = true
                } label: {
                    Label(sending ? "Sending…" : priming ? "Priming…" : "Start prime", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(sending || priming || !fresh || requiresRefresh)
                    .padding(16).background(Theme.background)
            }
            .confirmationDialog("Start priming?", isPresented: $confirmPrime, titleVisibility: .visible) {
                Button("Start priming") { Task { await startPrime() } }
            } message: { Text("Confirm that the water tank has been refilled and properly seated.") }
            .background(Theme.background)
            .navigationTitle("Water & Priming").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await device.fetchStatus() }
        }
    }
    private var waterDescription: String {
        isLow ? "Water level is low — refill and prime" : isKnownGood ? "Water level is good" : "Water level is unavailable"
    }
    private func startPrime() async {
        guard fresh, !priming, !sending, !requiresRefresh else { return }
        sending = true; primeResult = nil
        defer { sending = false }
        do {
            try await APIBackend.current.createClient().startPriming()
            primeResult = "Prime request accepted. Controller status shows whether priming is active."
        } catch { primeResult = "The prime request was not confirmed. Refresh controller status before trying again. \(error.localizedDescription)" }
        requiresRefresh = true
        await device.fetchStatus()
    }
}
