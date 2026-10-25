import SwiftUI

struct BaseCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @AppStorage("simpleBedView") private var simpleBedView = false
    @State private var head = 0.0
    @State private var feet = 0.0
    var body: some View {
        SleepCard(title: "Find your position", eyebrow: "POD ULTRA BASE", badge: "Experimental") {
            VStack(spacing: 0) {
                if simpleBedView { BedPreview(head: head, feet: feet) }
                else { BedSceneView(head: head, feet: feet) }
                Text("Position preview · moves the whole bed").sleepText(.caption).foregroundStyle(SleepTheme.secondary).frame(maxWidth: .infinity)
            }.padding(.horizontal, 16).padding(.vertical, 8).background(SleepTheme.canvas(scheme), in: .rect(cornerRadius: 12))
            Toggle("Simple 2D preview", isOn: $simpleBedView).toggleStyle(SleepCheckboxStyle())
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { presetButtons }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) { presetButtons }
            }
            VStack {
                HStack { Text("Head"); Spacer(); Text("\(Int(head))°") }
                SleepSlider(title: "Head angle preview", value: $head, range: 0...60)
                HStack { Text("Feet"); Spacer(); Text("\(Int(feet))°") }
                SleepSlider(title: "Feet angle preview", value: $feet, range: 0...45)
            }
            if let position = model.base?.position, model.base?.stale == false {
                Text("Reported · head \(Int(position.left.head))° / \(Int(position.right.head))° · feet \(Int(position.left.feet))° / \(Int(position.right.feet))°")
                    .sleepText(.caption).foregroundStyle(SleepTheme.secondary)
            } else { Text("Live position unavailable. Connect the base before moving.").sleepText(.caption).foregroundStyle(SleepTheme.secondary) }
            HStack(spacing: 8) {
                if model.base?.state == "connected" {
                    Button("Move bed") { Task { await model.moveBase(head: head, feet: feet) } }
                        .buttonStyle(SleepButtonStyle(kind: .primary, fill: true)).disabled(model.base?.ready != true || model.acting)
                } else {
                    Button("Connect base") { Task { await model.connectBase() } }.buttonStyle(SleepButtonStyle(kind: .primary, fill: true)).disabled(model.acting)
                }
                Button("Stop", role: .destructive) { Task { await model.stopBase() } }
                    .buttonStyle(SleepButtonStyle()).disabled(model.base?.state != "connected" || model.stopping)
            }.controlSize(.large)
        }
    }
    private var presetButtons: some View {
        ForEach(BasePreset.allCases, id: \.self) { preset in
            Button(preset.rawValue.capitalized) { head = preset.head; feet = preset.feet }
                .buttonStyle(SleepButtonStyle(kind: head == preset.head && feet == preset.feet ? .primary : .outlined,
                    fill: true, horizontalPadding: 8))
                .accessibilityAddTraits(head == preset.head && feet == preset.feet ? .isSelected : [])
        }
    }
}
