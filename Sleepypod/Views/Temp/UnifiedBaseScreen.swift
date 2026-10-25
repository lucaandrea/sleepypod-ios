import SwiftUI
import FreeSleepKit

struct UnifiedBaseScreen: View {
    var body: some View {
        if APIBackend.current == .freeSleep { PodFeatureScreen(.base) }
        else { CoreBaseScreen() }
    }
}

private struct CoreBaseScreen: View {
    @State private var model = BaseWorkspace(demo: APIBackend.current.isDemo)
    @Environment(SettingsManager.self) private var settings
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("base.mattress") private var mattress = true
    @AppStorage("base.simple") private var simple = false
    @AppStorage("base.instantPresets") private var instant = false
    @AppStorage("base.linked") private var linked = false
    @AppStorage("base.cards") private var cards = false
    @AppStorage("base.scope") private var savedScope = BaseScope.both
    @State private var resetCamera = 0

    private var scope: BaseScope { model.effectiveScope(savedScope) }
    private var useCards: Bool { model.independent && cards }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                status
                preferences
                if model.independent {
                    Picker("Base layout", selection: $cards) {
                        Text("Single card").tag(false)
                        Text("Side cards").tag(true)
                    }.pickerStyle(.segmented)
                    if useCards {
                        Toggle("Move both sides together", isOn: $linked).tint(Theme.green)
                    } else {
                        Picker("Selected sides", selection: $savedScope) {
                            ForEach(BaseScope.allCases) { Text(name($0)).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                }
                if useCards {
                    positionCard(.left)
                    positionCard(.right)
                } else { positionCard(scope) }
                BaseSchedulesScreen(model: model)
            }.frame(maxWidth: 720).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Bed position").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Stop", systemImage: "stop.fill", role: .destructive) { Task { await model.stop() } }
                    .tint(Theme.red).disabled(model.stopping).accessibilityHint("Stops both sides, including when position is unavailable")
            }
        }
        .refreshable { await model.refresh(); await model.loadSchedules() }
        .task { await model.loadSchedules() }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: linked) { _, enabled in if enabled { model.matchDrafts() } }
        .onChange(of: cards) { _, enabled in if enabled && linked { model.matchDrafts() } }
    }
    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(model.demo ? "DEMO · SIMULATED BASE" : "BASE · \(model.measured == nil ? "UNAVAILABLE" : model.status?.isMoving(.both) == true ? "MOVING" : "IDLE")")
            Text(model.readiness).font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if model.demo { Text("Changes stay in this preview. No commands reach your bed.").font(.footnote).foregroundStyle(Theme.text3) }
            if model.measured == nil {
                Button(model.reconnecting ? "Reconnecting…" : "Reconnect base") { Task { await model.reconnect() } }
                    .disabled(model.busy).frame(minHeight: 44)
            }
            if let error = model.commandError {
                Text(error).font(.footnote).foregroundStyle(Theme.red).accessibilityAddTraits(.updatesFrequently)
            }
            if let notice = model.notice {
                Text(notice).font(.footnote).foregroundStyle(Theme.text2).accessibilityAddTraits(.updatesFrequently)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var preferences: some View {
        GroupedCard {
            SettingsRow("Show mattress", icon: "bed.double") {
                Toggle("Show mattress", isOn: $mattress).labelsHidden().tint(Theme.green)
            }
            SettingsRow("Simple bed view", icon: "rectangle.split.3x1") {
                Toggle("Simple bed view", isOn: $simple).labelsHidden().tint(Theme.green)
            }
            SettingsRow("Move on preset selection", subtitle: "When off, presets only change the preview.", icon: "hand.tap") {
                Toggle("Move on preset selection", isOn: $instant).labelsHidden().tint(Theme.green)
            }.padding(.vertical, 8)
        }
    }
    private func positionCard(_ requested: BaseScope) -> some View {
        let selected = model.effectiveScope(requested, linked: useCards && linked)
        let target = model.targets[selected]
        let shown = model.previewRequested ? model.targets : (model.measured ?? .flat)
        return VStack(spacing: 18) {
            HStack {
                Text(useCards ? name(requested) : "Position").font(.headline)
                Spacer()
            Text(model.measured == nil ? "UNAVAILABLE" : model.status?.isMoving(selected) == true ? "MOVING" : model.atTarget(selected) ? "AT TARGET" : "NOT APPLIED")
                    .font(.mono(10, relativeTo: .caption)).foregroundStyle(Theme.text3)
            }
            Picker("Bed rendering", selection: $model.previewRequested) {
                Text("Reported").tag(false)
                Text("Preview").tag(true)
            }.pickerStyle(.segmented)
            Group {
                if simple {
                    SimpleBaseView(left: shown.left, right: shown.right, mattress: mattress)
                } else {
                    PositionBedScene(head: shown.left.head, feet: shown.left.feet, mattress: mattress,
                                     rightHead: shown.right.head, rightFeet: shown.right.feet, cameraReset: resetCamera)
                }
            }
            .frame(height: 230)
            .opacity(!model.previewRequested && model.measured == nil ? 0.35 : 1)
            .accessibilityLabel(model.previewRequested ? "Requested position preview" : "Measured bed position")
            .overlay {
                if !model.previewRequested && model.measured == nil { Text("Position unavailable").font(.callout) }
            }
            if !simple {
                HStack {
                    Text("Drag to rotate · pinch to zoom").font(.caption).foregroundStyle(Theme.text3)
                    Spacer()
                    Button("Reset view", systemImage: "arrow.counterclockwise") { resetCamera += 1 }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
            }
            measuredRows
            Divider()
            BaseAngleControls(angles: Binding(get: { model.targets[selected] }, set: { model.edit($0, scope: selected) }))
            BaseSpeedPicker(speed: $model.speed)
            Button { Task { await model.move(selected) } } label: {
                Text(typeSize.isAccessibilitySize && model.canMove(selected) ? (model.demo ? "Simulate move" : "Move bed") : moveTitle(selected))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
                .buttonStyle(PrimaryButtonStyle()).disabled(!model.canMove(selected))
                .accessibilityLabel(moveTitle(selected))
                .accessibilityIdentifier("base.move.\(requested.rawValue)")
            VStack(spacing: 0) {
                ForEach(BasePreset.allCases) { preset in
                    Button {
                        Task { await model.selectPreset(preset, scope: requested, linked: useCards && linked, immediately: instant) }
                    } label: {
                        presetLabel(preset, selected: target == preset.angles)
                    }.buttonStyle(.plain).disabled(model.busy)
                     .accessibilityIdentifier("base.preset.\(requested.rawValue).\(preset.rawValue)")
                    if preset != .read { Divider() }
                }
            }
        }.cardStyle()
    }
    private func presetLabel(_ preset: BasePreset, selected: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                BaseProfileShape(angles: preset.angles).stroke(Theme.text2, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 40, height: 22).accessibilityHidden(true)
                Text(preset.title).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !typeSize.isAccessibilitySize { Spacer() }
            HStack {
                Text(preset.angles.label).font(.mono(13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if selected { Image(systemName: "checkmark").font(.system(size: 17)).foregroundStyle(Theme.green) }
            }
        }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.vertical, typeSize.isAccessibilitySize ? 10 : 0).contentShape(Rectangle())
    }
    private var measuredRows: some View {
        VStack(spacing: 6) {
            ForEach([BaseScope.left, .right]) { side in
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())) {
                    Text(name(side)).font(.callout).foregroundStyle(Theme.text2)
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Text(model.measured?[side].label ?? "—").font(.mono(15))
                }
            }
            Text(model.demo ? "Simulated measurements" : "Measured head / feet")
                .font(.caption).foregroundStyle(Theme.text3).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func name(_ scope: BaseScope) -> String {
        scope == .both ? "Both sides" : settings.sideName(for: scope == .left ? .left : .right)
    }
    private func moveTitle(_ scope: BaseScope) -> String {
        if model.sending { return "Sending…" }
        if model.status?.isMoving(scope) == true { return "Moving" }
        if model.atTarget(scope) { return "At target" }
        return "\(model.demo ? "Simulate" : "Move") \(name(scope).lowercased()) to \(model.targets[scope].label)"
    }
}

struct BaseAngleControls: View {
    @Binding var angles: BaseAngles
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: 14) {
            angle("Head", value: Binding(get: { angles.head }, set: { angles.head = $0 }), maximum: 60)
            angle("Feet", value: Binding(get: { angles.feet }, set: { angles.feet = $0 }), maximum: 45)
        }
    }
    private func angle(_ title: String, value: Binding<Double>, maximum: Double) -> some View {
        VStack(spacing: 4) {
            if typeSize.isAccessibilitySize {
                HStack {
                    Text(title).font(.callout)
                    Spacer()
                    Text("\(Int(value.wrappedValue))°").font(.mono(20))
                }
                Stepper("\(title) angle", value: value, in: 0...maximum, step: 1).labelsHidden()
                    .accessibilityValue("\(Int(value.wrappedValue)) degrees")
            } else {
                HStack {
                    Text(title).font(.callout)
                    Spacer()
                    Stepper(value: value, in: 0...maximum, step: 1) {
                        Text("\(Int(value.wrappedValue))°").font(.mono(20)).frame(maxWidth: .infinity, alignment: .trailing)
                    }.accessibilityLabel("\(title) angle").accessibilityValue("\(Int(value.wrappedValue)) degrees")
                }
            }
            Slider(value: value, in: 0...maximum, step: 1) { Text("\(title) angle") }
        }
    }
}

struct BaseSpeedPicker: View {
    @Binding var speed: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Movement speed").font(.callout).foregroundStyle(Theme.text2)
            if typeSize.isAccessibilitySize { picker.pickerStyle(.menu).labelsHidden() }
            else { picker.pickerStyle(.segmented) }
            Text("This base requires at least 30% speed.").font(.caption).foregroundStyle(Theme.text3)
        }
    }
    private var picker: some View {
        Picker("Movement speed", selection: $speed) {
            if ![50, 75, 100].contains(speed) { Text("\(speed)%").tag(speed) }
            Text("50%").tag(50); Text("75%").tag(75); Text("100%").tag(100)
        }
    }
}

/// Shared four-panel profile, including the knee and slightly descending foot panel.
struct BaseProfileShape: Shape {
    let angles: BaseAngles
    func path(in rect: CGRect) -> Path {
        let headRadians = angles.head * .pi / 180
        let footRadians = angles.feet * .pi / 180
        let points = [CGPoint(x: 0.38 - 0.36 * cos(headRadians), y: 0.76 - 0.66 * sin(headRadians)),
                      CGPoint(x: 0.38, y: 0.76), CGPoint(x: 0.54, y: 0.76),
                      CGPoint(x: 0.54 + 0.17 * cos(footRadians), y: 0.76 - 0.32 * sin(footRadians)),
                      CGPoint(x: 0.54 + 0.17 * cos(footRadians) + 0.27 * cos(footRadians * 0.25),
                              y: 0.76 - 0.32 * sin(footRadians) + 0.5 * sin(footRadians * 0.25))]
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
        return path
    }
}

private struct SimpleBaseView: View {
    let left: BaseAngles
    let right: BaseAngles
    let mattress: Bool
    var body: some View {
        VStack(spacing: 18) {
            profile(left, title: "Left")
            profile(right, title: "Right")
        }.padding(.horizontal, 12)
    }
    private func profile(_ angles: BaseAngles, title: String) -> some View {
        VStack(spacing: 0) {
            Text("\(title) · \(angles.label)").font(.mono(12)).foregroundStyle(Theme.text2)
            BaseProfileShape(angles: angles)
                .stroke(Theme.text1, style: StrokeStyle(lineWidth: mattress ? 14 : 5, lineCap: .round, lineJoin: .round))
        }
    }
}
