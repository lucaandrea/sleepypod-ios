import SwiftUI

struct TempControlsView: View {
    @Environment(DeviceManager.self) private var device
    @Environment(UserProfile.self) private var profile
    @Environment(SettingsManager.self) private var settings
    /// The stepper has its own − / +, so it only needs power here.
    var powerOnly = false
    private var target: Int { device.currentSideStatus?.targetTemperatureF ?? 80 }

    var body: some View {
        TemperatureActionButtons(
            powered: device.isOn, powerOnly: powerOnly, canPower: true,
            canDecrease: !device.controlsBlocked(for: device.selectedSide.primarySide) && target > 55,
            canIncrease: !device.controlsBlocked(for: device.selectedSide.primarySide) && target < 110,
            onPower: { Haptics.medium(); device.togglePower() },
            onStep: { delta in
                Haptics.light()
                device.setTemperature(profile.temperatureDisplay.step(target, by: delta, unit: settings.temperatureFormat))
            })
    }
}

/// Transport-free controls shared by owner and separately scoped personal workspaces.
struct TemperatureActionButtons: View {
    let powered: Bool?
    var powerOnly = false
    let canPower: Bool
    let canDecrease: Bool
    let canIncrease: Bool
    let onPower: () -> Void
    let onStep: (Int) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 28) {
            HStack(spacing: 28) {
                if !powerOnly { step("minus", delta: -1) }
                Button(action: onPower) {
                    if powered == true {
                        Image(systemName: "power").font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Theme.background)
                            .frame(width: 64, height: 64)
                            .background(Theme.text1, in: Circle())
                    } else {
                        Image(systemName: "power").font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Theme.text1)
                            .frame(width: 64, height: 64)
                            .chromeSurface(Circle())
                    }
                }
                .accessibilityLabel(powered.map { $0 ? "Turn off" : "Turn on" } ?? "Power unavailable")
                .disabled(!canPower)
                if !powerOnly { step("plus", delta: 1) }
            }.buttonStyle(.plain)
        }
    }

    private func step(_ symbol: String, delta: Int) -> some View {
        Button { onStep(delta) } label: {
            Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Theme.text1)
                .frame(width: 64, height: 64).chromeSurface(Circle())
        }
        .accessibilityLabel(delta < 0 ? "Decrease temperature" : "Increase temperature")
        .disabled(delta < 0 ? !canDecrease : !canIncrease)
        .opacity(powered == true ? 1 : 0.45)
    }
}
