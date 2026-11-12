import SwiftUI

public struct PersonalHealthScreen: View {
    @Bindable private var model: PersonalHealthWorkspace
    @State private var confirmedOwnHealth = false
    @State private var confirmForget = false
    private let example: Bool
    @Environment(\.dismiss) private var dismiss

    public init(model: PersonalHealthWorkspace) { self.model = model; example = false }
    init(model: PersonalHealthWorkspace, example: Bool) { self.model = model; self.example = example }

    public var body: some View {
        FeaturePage(title: "Your Health history") {
            VStack(alignment: .leading, spacing: 22) {
                if example { Label("Example · no real Health access", systemImage: "play.circle").font(.subheadline) }
                Text("Health for \(model.displayName)").font(.title2.bold()).accessibilityIdentifier("personalHealth.person")
                switch model.status {
                case .consentRequired: enrollment
                case .ready: connected
                case .anotherAccount:
                    ContentUnavailableView("Health is linked elsewhere", systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("This device’s Health library is already linked to another personal account. Use your own iPhone or iPad. To remove an old link, go back to Personal account and review Erase personal local data."))
                        .accessibilityIdentifier("personalHealth.otherAccount")
                case .unavailable:
                    ContentUnavailableView("Saved Health is unavailable", systemImage: "lock",
                        description: Text("Unlock this device and try again. An unreadable import will not be replaced."))
                    Button("Try reading the saved copy") { model.restore() }.buttonStyle(FeatureActionButtonStyle())
                case .invalidated:
                    ContentUnavailableView("Reopen your personal account", systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Your account or device access changed. Your Health history has been hidden."))
                    Button("Back to your account") { dismiss() }.buttonStyle(FeatureActionButtonStyle())
                }
                if let message = model.message {
                    Text(message).font(.subheadline).foregroundStyle(Theme.text2)
                        .accessibilityIdentifier("personalHealth.message")
                }
                privacy
            }.frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task { await model.refreshOnActivation() }
        .onDisappear { model.cancelImport(); confirmedOwnHealth = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            model.invalidate(); confirmedOwnHealth = false
        }
        .alert("Remove this personal Health import?", isPresented: $confirmForget) {
            Button("Remove import", role: .destructive) { model.forget(); confirmedOwnHealth = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the imported history and its account link from this device. Apple Health, your bed routines and the existing owner workspace are unchanged.")
        }
    }

    private var enrollment: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Use the device that holds your Health records").font(.headline)
            Text("Apple Health belongs to the person using this device. A bed invitation does not tell us whose Health records are on it.")
                .foregroundStyle(Theme.text2)
            Text("Read your accessible sleep history, resting heart rate, HRV and respiration. Each sleep source stays separate.")
                .foregroundStyle(Theme.text2)
            Toggle("These are my own Health records", isOn: $confirmedOwnHealth).tint(Theme.green)
                .accessibilityIdentifier("personalHealth.consent")
            Button("Connect my Health history") {
                model.enroll(confirmedOwnHealth: confirmedOwnHealth)
                Task { await model.importHistory() }
            }.buttonStyle(FeatureActionButtonStyle(primary: true)).disabled(!confirmedOwnHealth || !model.mayEnroll)
                .accessibilityIdentifier("personalHealth.connect")
            if !model.mayEnroll {
                Text("Reconnect to your personal account before linking Health.").font(.footnote).foregroundStyle(Theme.text2)
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Linked to your account", systemImage: "checkmark.shield").font(.headline)
                .accessibilityIdentifier("personalHealth.linked")
            if let imported = model.importedAt {
                Text("Last read \(imported.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline).foregroundStyle(Theme.text2).accessibilityIdentifier("personalHealth.lastRead")
            }
            if !model.sources.isEmpty {
                sourceMenu
                if let selected = model.sources.first(where: { $0.id == model.selectedSource }) {
                    Text("\(selected.recordedDays.formatted()) recorded days from \(selected.name)")
                        .font(.headline).accessibilityIdentifier("personalHealth.coverage")
                    Text("A day may contain partial sleep or naps. Recorded days are not a count of confirmed complete training nights.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                }
            } else if model.importedAt != nil {
                Text("No readable sleep records").font(.headline).accessibilityIdentifier("personalHealth.empty")
                Text("This can mean no records or no permission. Apple Health does not reveal which. Check sleepypod’s access in Health, then refresh.")
                    .foregroundStyle(Theme.text2)
            }
            if model.busy {
                ProgressView("Reading Health history…").accessibilityIdentifier("personalHealth.progress")
                Button("Cancel import") { model.cancelImport() }.buttonStyle(FeatureActionButtonStyle())
            } else {
                Button(model.importedAt == nil ? "Read Health history" : "Refresh Health history") {
                    Task { await model.importHistory() }
                }.buttonStyle(FeatureActionButtonStyle(primary: true)).disabled(!model.mayImport)
                    .accessibilityIdentifier("personalHealth.refresh")
            }
            if !model.mayImport && !model.busy {
                Text("Your saved copy is available. Reconnect to your personal account to read new Health data.")
                    .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("personalHealth.offline")
            }
            if model.importedAt != nil {
                Toggle("Refresh when I open this account", isOn: Binding(get: { model.automaticRefresh }, set: model.setAutomaticRefresh))
                    .tint(Theme.green).disabled(model.busy).accessibilityIdentifier("personalHealth.automatic")
                Text("Check for new records at most every 30 minutes in the morning, or every six hours otherwise. This does not retrain a model or create a report.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }
            Button("Remove this Health import", role: .destructive) { confirmForget = true }
                .buttonStyle(FeatureActionButtonStyle()).accessibilityIdentifier("personalHealth.forget")
        }
    }

    // A wrapping label keeps the selected provenance readable at every text size.
    private var sourceMenu: some View {
        Menu {
            ForEach(model.sources) { source in
                Button { model.selectSource(source.id) } label: {
                    if source.id == model.selectedSource {
                        Label(source.name, systemImage: "checkmark")
                    } else { Text(source.name) }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sleep source").font(.subheadline).foregroundStyle(Theme.text2)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(model.sources.first(where: { $0.id == model.selectedSource })?.name ?? "Choose a source")
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.footnote).accessibilityHidden(true)
                }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .disabled(model.busy).accessibilityIdentifier("personalHealth.source")
        .accessibilityLabel("Sleep source")
        .accessibilityValue(model.sources.first(where: { $0.id == model.selectedSource })?.name ?? "Choose a source")
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Private on this device", systemImage: "lock").font(.headline)
            Text("Linking Health does not copy another sleeper’s records, send data to the Pod or an AI provider, or change the bed. You can change read access in Apple Health at any time.")
                .font(.footnote).foregroundStyle(Theme.text2)
        }
    }
}
