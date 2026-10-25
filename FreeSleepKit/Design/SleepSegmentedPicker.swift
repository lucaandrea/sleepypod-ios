import SwiftUI

struct SleepSegmentedPicker<Value: Hashable>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    var label: (Value) -> String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: SleepTokens.Layout.selectorInset) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(label(option)).sleepText(.small).multilineTextAlignment(.center)
                        .padding(.horizontal, 8).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, minHeight: SleepTokens.Layout.controlHeight)
                        .foregroundStyle(selection == option ? SleepTheme.text : SleepTheme.secondary)
                        .background(selection == option ? SleepTheme.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 7))
                        .contentShape(.rect)
                }.buttonStyle(.plain).accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }.padding(SleepTokens.Layout.selectorInset + 1)
            .overlay(RoundedRectangle(cornerRadius: SleepTokens.Layout.selectorRadius).strokeBorder(SleepTheme.border(scheme)))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}
