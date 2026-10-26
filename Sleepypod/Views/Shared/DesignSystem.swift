import SwiftUI

struct SettingsToolbar: ViewModifier {
    @State private var presented = ["settings", "allsettings", "health", "autopilot"].contains(DebugRoute.current)
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { presented = true }
            }
        }
        .sheet(isPresented: $presented) { SettingsSheet() }
    }
}

extension View {
    func settingsToolbar() -> some View { modifier(SettingsToolbar()) }
}
