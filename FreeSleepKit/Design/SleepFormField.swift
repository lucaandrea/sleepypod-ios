import SwiftUI

struct SleepFormField<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sleepText(.small).foregroundStyle(SleepTheme.secondary)
            content.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SleepTheme.border(scheme)))
        }
    }
}
struct SleepNotesField: View {
    let title: String
    let limit: Int
    @Binding var text: String
    var body: some View {
        SleepFormField(title: title) {
            TextField(title, text: $text, axis: .vertical).lineLimit(3...8).textFieldStyle(.plain)
                .sleepText(.body).padding(.vertical, 12).accessibilityLabel(title)
                .onChange(of: text) { text = InputText.limit(text, to: limit) }
        }
    }
}
struct SleepCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22)).foregroundStyle(configuration.isOn ? SleepTheme.accent : SleepTheme.secondary)
                configuration.label.sleepText(.body).foregroundStyle(SleepTheme.text).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }.frame(minHeight: 44, alignment: .center)
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "Selected" : "Not selected")
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}
