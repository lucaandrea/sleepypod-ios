import SwiftUI
import CoreImage.CIFilterBuiltins
import ImageIO

struct HomeKitBridgeScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model = HomeKitBridgeWorkspace(client: APIBackend.current.isDemo ? DemoHomeKitBridgeClient() : CoreHomeKitBridgeClient())
    @State private var confirmReset = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if APIBackend.current.isDemo { Text("DEMO · changes affect simulated settings only").font(.footnote).foregroundStyle(Theme.amber) }
                Text("Add your Pod to Apple Home with its local HomeKit bridge.").font(.subheadline).foregroundStyle(Theme.text2)
                TimelineView(.periodic(from: .now, by: 1)) { _ in bridgeCard }
                if model.loading && model.status == nil { ProgressView("Reading bridge state…") }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                if let error = model.actionError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                if let receipt = model.receipt { Text(receipt).font(.footnote).accessibilityIdentifier("homekit.receipt") }
                Button("Refresh bridge state") { Task { await model.refresh() } }
                    .disabled(model.loading || model.changing).accessibilityIdentifier("homekit.refresh")
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity, alignment: .center)
        }.background(Theme.background).navigationTitle("HomeKit bridge").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("homekit.content")
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                repeat {
                    await model.refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                } while !Task.isCancelled
            }
            .confirmationDialog("Reset HomeKit pairing?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset pairing", role: .destructive) { Task { await model.resetPairing() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This gives the bridge a new identity, setup code and QR code. Remove the old bridge from Apple Home, where its tiles will otherwise show No Response, then pair again.")
            }
    }
    private var bridgeCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
            layout {
                Label("HOMEKIT", systemImage: "house").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                if !typeSize.isAccessibilitySize { Spacer() }
                Text(model.changing ? "Changing…" : model.fresh() ? model.status?.stateLabel ?? "Unknown" : "Unavailable")
                    .font(.subheadline).foregroundStyle(model.fresh() && model.status?.running == true ? Theme.green : Theme.text2)
            }
            if let status = model.status {
                BridgeToggleRow(title: "HomeKit bridge", value: Binding(get: { status.enabled }, set: { enabled in Task { await model.setEnabled(enabled) } }), identifier: "homekit.enabled")
                    .disabled(!model.canChange)
                if model.fresh() && !model.changing {
                    SensorDiagnosticValue(title: "Paired controllers", value: "\(status.pairedControllers.count)").accessibilityIdentifier("homekit.pairedCount")
                    if status.enabled && status.running && status.transitioning != true {
                        if status.pairedControllers.isEmpty {
                            Text("Open Apple Home and choose Add Accessory. Scan this code from another screen or enter the setup code.").font(.footnote).foregroundStyle(Theme.text2)
                        }
                        if let code = status.formattedCode {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Setup code").font(.caption).foregroundStyle(Theme.text2)
                                Text(code).font(.title2.monospaced()).lineLimit(1).minimumScaleFactor(0.6).textSelection(.enabled).privacySensitive().accessibilityIdentifier("homekit.setupCode")
                            }
                        }
                        if status.qrDataUrl != nil || status.setupURI != nil { HomeKitPairingImage(status: status) }
                        if !status.pairedControllers.isEmpty {
                            Button("Reset HomeKit pairing", role: .destructive) { confirmReset = true }
                                .disabled(!model.canChange).accessibilityIdentifier("homekit.reset")
                        }
                    }
                } else {
                    Text("Refresh to read the current bridge state and pairing information.").font(.footnote).foregroundStyle(Theme.text2)
                }
            }
        }.cardStyle()
    }
}

struct BridgeToggleRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    @Binding var value: Bool
    let identifier: String
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                Toggle(title, isOn: $value).labelsHidden().accessibilityIdentifier(identifier)
            }
        } else { Toggle(title, isOn: $value).accessibilityIdentifier(identifier) }
    }
}

private struct HomeKitPairingImage: View {
    let status: HomeKitBridgeStatus
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 180, height: 180).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("HomeKit pairing QR code").accessibilityIdentifier("homekit.qrCode").privacySensitive()
            } else { Text("Pairing QR unavailable. Use the setup code.").font(.footnote).foregroundStyle(Theme.text2) }
        }.task(id: status.qrDataUrl ?? status.setupURI) { image = decodePairingImage() }
    }
    // Only decode a small local PNG, or generate the supplied HomeKit setup URI locally.
    private func decodePairingImage() -> UIImage? {
        if let encoded = status.qrDataUrl, encoded.hasPrefix("data:image/png;base64,"), encoded.utf8.count < 350_000,
           let data = Data(base64Encoded: String(encoded.dropFirst(22))),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
           (1...1024).contains(width), (1...1024).contains(height) { return UIImage(data: data) }
        guard let uri = status.setupURI, uri.hasPrefix("X-HM://"), uri.utf8.count <= 64 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8); filter.correctionLevel = "Q"
        guard let output = filter.outputImage, let bitmap = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: bitmap)
    }
}
