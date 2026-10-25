import SwiftUI

struct RoutineCopyFields: View {
    let day: String
    @Binding var copies: Set<String>
    var body: some View {
        FeatureSection(title: "Copy to other days", eyebrow: "COPY TO OTHER DAYS") {
            Text("Copies include power, temperature and alarm settings for this side.").font(.subheadline).foregroundStyle(Theme.text2)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                Button("Weekdays") { copies = Set(RoutinePlan.days.prefix(5)).subtracting([day]) }
                Button("Weekends") { copies = Set(RoutinePlan.days.suffix(2)).subtracting([day]) }
                Button("Every day") { copies = Set(RoutinePlan.days).subtracting([day]) }
                Button("Clear") { copies = [] }
            }.buttonStyle(GlassButtonStyle())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 0) {
                ForEach(RoutinePlan.days, id: \.self) { target in
                    let selected = target == day || copies.contains(target)
                    Button {
                        if selected { copies.remove(target) } else { copies.insert(target) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).foregroundStyle(Theme.text1)
                            Text(target.capitalized).font(.body)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).disabled(target == day).accessibilityLabel("Copy to \(target.capitalized)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Text("Saving replaces the full routine on: " + ([day] + RoutinePlan.days.filter { copies.contains($0) }).map(\.capitalized).joined(separator: ", ") + ".")
                .font(.caption).foregroundStyle(Theme.text2)
        }
    }
}
