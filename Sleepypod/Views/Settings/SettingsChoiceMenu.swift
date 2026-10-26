import SwiftUI

/// A menu value can wrap to multiple lines at accessibility sizes without the system picker's fixed label height.
struct SettingsChoiceMenu: View {
    let title: String
    @Binding var selection: String
    let options: [(String, String)]
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(options.first { $0.0 == selection }?.1 ?? selection)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                }.frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(options.first { $0.0 == selection }?.1 ?? selection)
                .accessibilityIdentifier(identifier)
        }
    }
}
