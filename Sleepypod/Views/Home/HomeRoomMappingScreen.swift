import SwiftUI

struct HomeRoomMappingScreen: View {
    @Environment(HomeRoomSession.self) private var session
    @State private var review: HomeRoomWorkspace.Save?
    @State private var confirmSave = false
    @State private var confirmReload = false
    @State private var localError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Use existing Home Assistant sensor entities with a verified measurement timestamp. Inspect the entity’s attributes in Developer tools → States. An integration refresh time or a timestamp added with ‘now’ cannot establish a new measurement.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if let model = session.workspace, model.base != nil {
                    if model.isSyntheticExample { Text("SYNTHETIC EXAMPLE · changes stay in memory.").font(.footnote).foregroundStyle(Theme.amber) }
                    configuration(model)
                    if model.conflict { Text("The saved mapping changed. Your draft is preserved.").foregroundStyle(Theme.amber) }
                    if let error = model.validationError { Text(error).font(.footnote).foregroundStyle(Theme.amber).accessibilityIdentifier("room.validation") }
                    if let message = model.notice { Text(message).font(.footnote).foregroundStyle(Theme.text2) }
                    if let error = model.error ?? localError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                    Button("Save room sensors") {
                        do { review = try model.reviewedSave(); confirmSave = true; localError = nil }
                        catch { localError = error.localizedDescription }
                    }.disabled(!model.canSave || (APIBackend.current.isDemo && !model.isSyntheticExample)).accessibilityIdentifier("room.save")
                    Button("Discard draft and reload saved mapping") { confirmReload = true }.disabled(model.saving || model.pending != nil)
                        .accessibilityIdentifier("room.reload")
                    Button("Refresh stored revision") { Task { await model.refresh() } }.disabled(model.saving || model.reading)
                    Text("Saving changes sensor input only. It does not enable Autopilot or control accessories. Every save creates a new revision, invalidates previous publishers, and waits for a new measurement.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                } else { Text("Room configuration is unavailable.").foregroundStyle(Theme.text2) }
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Sensor mapping").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Save this room mapping?", isPresented: $confirmSave, titleVisibility: .visible) {
                Button("Save mapping") { if let review { Task { await session.workspace?.save(review) } } }.accessibilityIdentifier("room.confirmSave")
                Button("Cancel", role: .cancel) { review = nil }
            } message: { Text("Replace all previous Home Assistant publisher documents after saving. Old readings will be withdrawn until new measurements arrive.") }
            .confirmationDialog("Discard this draft?", isPresented: $confirmReload, titleVisibility: .visible) {
                Button("Discard draft", role: .destructive) { session.workspace?.reloadDraft() }.accessibilityIdentifier("room.confirmReload")
                Button("Cancel", role: .cancel) {}
            }
    }
    private func configuration(_ model: HomeRoomWorkspace) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Room name").font(.headline)
                TextField("Room name", text: $model.draft.roomName).textFieldStyle(.roundedBorder).accessibilityIdentifier("room.name")
                Toggle("Accept mapped room measurements", isOn: $model.draft.enabled).accessibilityIdentifier("room.enabled")
            }.cardStyle()
            ForEach(HomeRoomMetric.allCases) { metric in
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Map \(metric.title.lowercased())", isOn: Binding(get: { model.draft.mappings.contains { $0.metric == metric } }, set: { enabled in
                        if enabled && !model.draft.mappings.contains(where: { $0.metric == metric }) { model.draft.mappings.append(.blank(metric)) }
                        else if !enabled { model.draft.mappings.removeAll { $0.metric == metric } }
                    })).accessibilityIdentifier("room.map.\(metric.rawValue)")
                    if model.draft.mappings.contains(where: { $0.metric == metric }) {
                        fields(Binding(get: { model.draft.mappings.first { $0.metric == metric } ?? .blank(metric) }, set: { mapping in
                            if let index = model.draft.mappings.firstIndex(where: { $0.metric == metric }) { model.draft.mappings[index] = mapping }
                        }), metric: metric)
                    }
                }.cardStyle()
            }
        }.disabled(model.saving || model.pending != nil)
    }
    private func fields(_ mapping: Binding<HomeRoomMapping>, metric: HomeRoomMetric) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Entity ID").font(.caption).foregroundStyle(Theme.text2)
            TextField("sensor.example_measurement", text: mapping.entityId).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("room.entity.\(metric.rawValue)")
            Menu {
                Picker("Source unit", selection: mapping.unit) { ForEach(metric.sourceUnits, id: \.self) { Text($0).tag($0) } }
            } label: { selectionLabel("Source unit", value: mapping.wrappedValue.unit) }
            Text("Measurement timestamp attribute").font(.caption).foregroundStyle(Theme.text2)
            TextField("Verified source attribute", text: mapping.timestampAttribute).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("room.timestamp.\(metric.rawValue)")
            Menu {
                Picker("Timestamp format", selection: mapping.timestampFormat) { ForEach(RoomTimestampFormat.allCases) { Text($0.title).tag($0) } }
            } label: { selectionLabel("Timestamp format", value: mapping.wrappedValue.timestampFormat.title) }
                .accessibilityIdentifier("room.format.\(metric.rawValue)")
            Text("Maximum age in seconds · 30–900").font(.caption).foregroundStyle(Theme.text2)
            TextField("Maximum age", value: mapping.maxAgeSeconds, format: .number.grouping(.never)).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("room.age.\(metric.rawValue)")
        }
    }
    private func selectionLabel(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(Theme.text2)
                Text(value).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Theme.text2)
        }.contentShape(Rectangle())
    }
}
