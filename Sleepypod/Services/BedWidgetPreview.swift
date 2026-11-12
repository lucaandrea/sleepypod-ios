#if DEBUG
import SwiftUI
import WidgetKit

/// Exercises the production widget view using synthetic values; it does not emulate SpringBoard scheduling.
struct BedWidgetPreview: View {
    private let now = Date()
    private var mode: String { UserDefaults.standard.string(forKey: "uiWidgetState") ?? "split" }
    private var family: WidgetFamily {
        switch UserDefaults.standard.string(forKey: "uiWidgetFamily") {
        case "medium": .systemMedium
        case "lock": .accessoryRectangular
        case "inline": .accessoryInline
        case "circle": .accessoryCircular
        default: .systemSmall
        }
    }
    private var snapshot: BedWidgetSnapshot? {
        guard mode != "missing" else { return nil }
        return .init(version: 1, assignment: "Both sides", zones: [
            .init(id: "left", requestedF: 68, powered: mode != "off"),
            .init(id: "right", requestedF: 88, powered: mode != "off")],
            nextWake: "Tomorrow at 7:00 AM. Warming starts at 6:30 AM toward 105°F. Vibration: 20 seconds.",
            checkedAt: now.addingTimeInterval(mode == "expired" ? -901 : mode == "overnight" ? -8 * 3_600 : -120),
            wake: mode == "overnight" ? .init(side: "right", at: now.addingTimeInterval(3_600), timeZone: "America/Los_Angeles",
                warmingAt: now.addingTimeInterval(1_800), targetF: 105, vibrationSeconds: 20) : nil)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .center, spacing: 24) {
                    Text("Synthetic widget example · no Pod connection").font(.caption).foregroundStyle(.secondary)
                    BedWidgetContent(entry: .init(date: now, snapshot: snapshot), family: family, showsBackground: true)
                        .padding(family == .systemSmall || family == .systemMedium ? 16 : 0)
                        .frame(maxWidth: family == .systemMedium ? 305 : family == .accessoryRectangular ? 158 : family == .accessoryCircular ? 76 : 141)
                        .frame(height: family == .accessoryInline ? 26 : family == .accessoryRectangular ? 72 : family == .accessoryCircular ? 76 : 141)
                        .background(.background, in: RoundedRectangle(cornerRadius: 24))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("widget.productionPreview")
                    Text("The real widget opens Tonight. Values are saved, never live; no bed commands run from this preview.")
                        .font(.body).frame(maxWidth: 380)
                }.frame(maxWidth: .infinity).padding()
            }.background(Color(.secondarySystemBackground)).navigationTitle("Widget previews")
        }
    }
}
#endif
