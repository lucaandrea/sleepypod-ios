import SwiftUI

struct SettingsMutationFeedback: View {
    @Environment(SettingsManager.self) private var settings
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.isSaving { ProgressView("Saving settings…") }
            else if settings.isLoading { ProgressView("Reading settings…") }
            if let error = settings.error { Text(error).font(.footnote).foregroundStyle(Theme.amber).accessibilityIdentifier("settings.saveError") }
            if settings.mustReloadSettings || settings.error != nil {
                Button("Reload settings") { Task { await settings.fetchSettings() } }.disabled(settings.isLoading || settings.isSaving)
                    .accessibilityIdentifier("settings.reconcile")
            }
        }
    }
}
