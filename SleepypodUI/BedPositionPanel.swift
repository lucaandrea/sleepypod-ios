import SceneKit
import SwiftUI

struct BedPositionPanel: View {
    @Binding var head: Double
    @Binding var feet: Double
    let reported: String
    let ready: Bool
    let moving: Bool
    let stopping: Bool
    let demo: Bool
    let message: String?
    let move: () -> Void
    let stop: () -> Void
    let reconnect: () -> Void
    @State private var mattress = true

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(demo ? "PREVIEW · DEMO" : "PREVIEW · BOTH SIDES")
                    PositionBedScene(head: head, feet: feet, mattress: mattress)
                        .frame(height: 220)
                        .accessibilityLabel("Bed preview, head \(Int(head)) degrees, feet \(Int(feet)) degrees")
                    Text("Drag to rotate").font(.mono(11, relativeTo: .caption)).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity)
                }.cardStyle()

                GroupedCard {
                    SettingsRow("Show mattress", icon: "bed.double") {
                        Toggle("Show mattress", isOn: $mattress).labelsHidden().tint(Theme.green)
                    }
                }
                GroupedSection("POSITION") {
                    GroupedCard {
                        angle("Head", value: $head, range: 0...60)
                        angle("Feet", value: $feet, range: 0...45)
                        SettingsRow("Reported", subtitle: reported, icon: "dot.radiowaves.left.and.right")
                    }
                    Text("Changes preview the whole bed. Tap Move bed to send them.")
                        .font(.footnote).foregroundStyle(Theme.text2).padding(.horizontal, 16)
                }
                GroupedSection("PRESETS") {
                    GroupedCard {
                        preset("Flat", head: 0, feet: 0)
                        preset("Sleep", head: 1, feet: 5)
                        preset("Relax", head: 30, feet: 15)
                        preset("Read", head: 40, feet: 0)
                    }.buttonStyle(.plain)
                }
                Button(moving ? "Sending…" : "Move bed", action: move)
                    .buttonStyle(PrimaryButtonStyle()).disabled(!ready || moving || demo)
                Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
                    .buttonStyle(GlassButtonStyle()).disabled(stopping || demo)
                Button("Reconnect base", action: reconnect).frame(minHeight: 44).disabled(moving || demo)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.updatesFrequently)
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
        }.background(Theme.background).navigationTitle("Bed position").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }

    private func angle(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 8) {
            HStack { Text(title).font(.callout); Spacer(); Text("\(Int(value.wrappedValue))°").font(.mono(18)) }
            Slider(value: value, in: range, step: 1) { Text("\(title) angle") }
        }.padding(16)
    }
    private func preset(_ title: String, head: Double, feet: Double) -> some View {
        Button { self.head = head; self.feet = feet; Haptics.tap() } label: {
            SettingsRow(title, icon: "bed.double") {
                RowValue("\(Int(head))° / \(Int(feet))°", mono: true)
                if self.head == head && self.feet == feet { Image(systemName: "checkmark").foregroundStyle(Theme.green) }
            }
        }
    }
}
