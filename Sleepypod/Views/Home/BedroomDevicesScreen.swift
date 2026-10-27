import SwiftUI

private struct BedroomEditSession: Identifiable {
    let id = UUID()
    let workspace: BedroomWorkspace
    let original: BedroomVersion
}

struct BedroomDevicesScreen: View {
    @Environment(BedroomSession.self) private var session
    @State private var editor: BedroomEditSession?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BedroomDevicesCard()
                if let model = session.workspace {
                    Button("Refresh bedroom devices", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.reading || model.saving)
                    if let status = model.status, !status.config.sources.isEmpty {
                        Button("Choose room inputs", systemImage: "slider.horizontal.3") { editor = .init(workspace: model, original: status.version) }
                            .disabled(model.saving || model.pending != nil || model.serverTime(at: .now) == nil)
                    }
                    if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
                }
                Text("Each physical sensor contributes once. Conflicting or expired climate readings are withheld. Air-quality categories, particle measurements and device power remain separate.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                Text("Existing Apple Home and Homebridge pairings stay in place. Discovery and publisher setup are managed on your home server.")
                    .font(.footnote).foregroundStyle(Theme.text2)
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Bedroom devices").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("bedroom.screen")
            .sheet(item: $editor) { session in
                NavigationStack { BedroomSelectionEditor(model: session.workspace, original: session.original) }
            }
    }
}

private struct BedroomSelectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: BedroomWorkspace
    let original: BedroomVersion
    @State private var draft: BedroomConfiguration
    init(model: BedroomWorkspace, original: BedroomVersion) {
        self.model = model; self.original = original; _draft = State(initialValue: original.config)
    }
    var body: some View {
        Form {
            Section {
                Toggle("Use bedroom context", isOn: $draft.enabled)
                TextField("Room name", text: $draft.roomName)
            }
            ForEach($draft.sources) { $source in
                Section(source.deviceName) {
                    Toggle(source.label, isOn: $source.enabled)
                    Toggle("Include in room context", isOn: $source.useForControl).disabled(!source.enabled)
                    Text("\(source.provider.title) · \(source.location.title) · \(source.unit)").font(.caption).foregroundStyle(Theme.text2)
                }
            }
            Section {
                Text("Saving withdraws current readings and requires publishers to use the new revision. It does not enable Autopilot.")
                if model.status?.version != original { Text("The selection changed on another device. Close and reopen this editor to review it.").foregroundStyle(Theme.amber) }
                if let notice = model.notice { Text(notice).foregroundStyle(Theme.amber) }
            }.font(.footnote)
        }.navigationTitle("Room inputs").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { if await model.save(draft, original: original) { await model.refresh(); dismiss() } } }
                        .disabled(model.reading || model.saving || model.pending != nil || model.status?.version != original || (try? draft.validate()) == nil)
                }
            }.interactiveDismissDisabled(model.saving)
    }
}
