import SwiftUI
import WidgetKit

struct BedWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BedWidgetEntry { .init(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (BedWidgetEntry) -> Void) {
        let now = Date()
        completion(.init(date: now, snapshot: BedWidgetStore.shared.read(at: now)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BedWidgetEntry>) -> Void) {
        let now = Date(), snapshot = BedWidgetStore.shared.read(at: Date())
        var entries = [BedWidgetEntry(date: now, snapshot: snapshot)]
        // Expiry is a scheduled timeline entry, independent of the next background refresh opportunity.
        if let snapshot {
            if now < snapshot.targetExpiresAt, snapshot.targetExpiresAt < snapshot.expiresAt {
                entries.append(.init(date: snapshot.targetExpiresAt, snapshot: snapshot))
            }
            entries.append(.init(date: snapshot.expiresAt, snapshot: nil))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

@main struct SleepypodBedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BedWidgetStore.kind, provider: BedWidgetProvider()) { BedWidgetView(entry: $0) }
            .configurationDisplayName("Bed status")
            .description("See your last checked bed target and wake plan. Open sleepypod for current controls.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
            .disfavoredLocations([.carPlay], for: [.systemSmall])
    }
}
