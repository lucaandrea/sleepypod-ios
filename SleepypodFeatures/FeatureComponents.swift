import SwiftUI

/// Detail pages use the same insets, surfaces and navigation as Sleepypod Settings.
struct FeaturePage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(Theme.text1).tint(Theme.text1)
    }
}

struct FeatureSection<Content: View>: View {
    let title: String
    var eyebrow = ""
    var badge: String?
    var badgeTone: FeatureStatus.Tone = .neutral
    var actionTitle: String?
    var action: (() -> Void)?
    @ViewBuilder var content: Content
    var body: some View {
        GroupedSection(title.uppercased()) {
            GroupedCard {
                VStack(alignment: .leading, spacing: 16) {
                    if let badge { FeatureStatus(title: badge, tone: badgeTone) }
                    if eyebrow.hasPrefix("POD LOCAL TIME") {
                        Text(eyebrow).font(.mono(11, relativeTo: .caption)).foregroundStyle(Theme.text2)
                    }
                    content
                    if let actionTitle, let action {
                        Button(actionTitle, action: action).font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct FeatureField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(Theme.text2)
            content.font(.body).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }
}

struct FeatureNotes: View {
    let title: String
    let limit: Int
    @Binding var text: String
    var body: some View {
        FeatureField(title: title) {
            TextField(title, text: $text, axis: .vertical)
                .lineLimit(3...8).padding(12)
                .background(Theme.active, in: RoundedRectangle(cornerRadius: 13))
                .accessibilityLabel(title)
                .onChange(of: text) { text = InputText.limit(text, to: limit) }
        }
    }
}

struct FeatureSegments<Value: Hashable>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
        } else {
            SegmentedControl(segments: options.map { .init(value: $0, title: label($0)) }, selection: $selection)
                .accessibilityLabel(title)
        }
    }
}

struct FeatureSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var body: some View { Slider(value: $value, in: range, step: step) { Text(title) } }
}

struct FeatureStatus: View {
    enum Tone { case neutral, success, info, error, warning }
    let title: String
    var tone: Tone = .neutral
    var dot = false
    private var color: Color {
        switch tone {
        case .neutral: Theme.text2
        case .success: Theme.green
        case .info: Theme.cool
        case .error: Theme.red
        case .warning: Theme.amber
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            if dot { StatusDot(color: color) }
            Eyebrow(title, color: color)
        }
    }
}
