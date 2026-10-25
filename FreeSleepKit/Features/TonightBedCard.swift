import SwiftUI

/// The bed overview opens explicit controls; rotating the scene never moves hardware.
struct TonightBedCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("simpleBedView") private var simpleBedView = false
    @State private var controls: Controls?

    private enum Controls: String, Identifiable {
        case temperature, position
        var id: String { rawValue }
        var title: String { self == .temperature ? "Temperature" : "Bed position" }
    }

    private var reportedPosition: BaseStatus.Angles? {
        guard model.base?.stale == false else { return nil }
        return model.base?.position?.left
    }

    var body: some View {
        VStack(spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { temperatureButtons }
                VStack(spacing: 12) { temperatureButtons }
            }
            Group {
                if simpleBedView || typeSize.isAccessibilitySize {
                    BedPreview(head: reportedPosition?.head ?? 0, feet: reportedPosition?.feet ?? 0)
                } else {
                    BedSceneView(head: reportedPosition?.head ?? 0, feet: reportedPosition?.feet ?? 0)
                }
            }
            Text(reportedPosition == nil
                 ? "Position unavailable · illustration only"
                 : "Reported position · physical movement unverified")
                .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Position", systemImage: "bed.double") { controls = .position }
                    .buttonStyle(SleepButtonStyle(fill: true))
                Button("Temperature", systemImage: "thermometer.medium") { controls = .temperature }
                    .buttonStyle(SleepButtonStyle(kind: .primary, fill: true))
            }
        }
        .padding(20)
        .background(SleepTheme.surface(scheme), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(SleepTheme.border(scheme)))
        .sheet(item: $controls) { selection in
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        if selection == .temperature {
                            SidePicker()
                            TemperatureCard().id(model.side)
                        } else {
                            BaseCard()
                        }
                        if let message = model.actionMessage {
                            Text(message).foregroundStyle(SleepTheme.error).accessibilityAddTraits(.updatesFrequently)
                        }
                    }.padding(20)
                }
                .background(SleepTheme.canvas(scheme))
                .navigationTitle(selection.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { controls = nil } } }
            }
        }
    }

    private var temperatureButtons: some View {
        ForEach(BedSide.allCases, id: \.self) { side in
            let status = model.device?[side]
            let away = model.settings?[side].awayMode == true
            Button {
                model.side = side
                controls = .temperature
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(side.title).sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(status.map { model.temperatureLabel($0.targetTemperatureF) + "°" } ?? "—")
                            .sleepText(.smallMetric)
                        Text(away ? "Away" : status.map { $0.isOn ? "On" : "Off" } ?? "Unavailable")
                            .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(SleepTheme.canvas(scheme), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(side.title) temperature controls")
            .accessibilityValue(status.map { "Target \(model.temperatureLabel($0.targetTemperatureF)) degrees" } ?? "Unavailable")
        }
    }
}
