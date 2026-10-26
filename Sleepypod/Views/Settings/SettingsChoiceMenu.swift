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
                SettingsChoiceOptions(selection: $selection, options: options, identifier: identifier)
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

/// Explicit actions allow server-confirmed bindings to update after a menu dismisses.
struct SettingsChoiceOptions: View {
    @Binding var selection: String
    let options: [(String, String)]
    let identifier: String
    var body: some View {
        ForEach(options, id: \.0) { option in
            Button { selection = option.0 } label: {
                if selection == option.0 { Label(option.1, systemImage: "checkmark") } else { Text(option.1) }
            }.accessibilityIdentifier("\(identifier).option.\(option.1)")
        }
    }
}
