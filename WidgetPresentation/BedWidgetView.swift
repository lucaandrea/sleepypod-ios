import SwiftUI
import WidgetKit

struct BedWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BedWidgetSnapshot?
}

struct BedWidgetView: View {
    let entry: BedWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    var body: some View { BedWidgetContent(entry: entry, family: family, showsBackground: showsBackground) }
}

struct BedWidgetContent: View {
    let entry: BedWidgetEntry
    let family: WidgetFamily
    let showsBackground: Bool
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        Group {
            if let snapshot = entry.snapshot, snapshot.isUsable(at: entry.date) {
                Group {
                    if snapshot.hasRecentTargets(at: entry.date) { status(snapshot) }
                    else if let wake = snapshot.savedWake(at: entry.date) { savedWake(wake, snapshot: snapshot) }
                    else { unavailable }
                }.privacySensitive()
            } else { unavailable }
        }
        .widgetURL(BedWidgetRoute.url)
        .containerBackground(.background, for: .widget)
    }

    @ViewBuilder private func status(_ snapshot: BedWidgetSnapshot) -> some View {
        if textSize.isAccessibilitySize, family == .systemSmall || family == .systemMedium {
            accessibleStatus(snapshot)
        } else { switch family {
        case .accessoryInline:
            Text("Bed: \(snapshot.targetLabel) · saved \(snapshot.checkedAt, style: .relative) ago")
        case .accessoryCircular:
            VStack(spacing: 2) {
                Text("Saved").font(.caption2)
                Text(snapshot.targetLabel.replacingOccurrences(of: "°F / ", with: "/"))
                    .font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.5)
            }.accessibilityLabel("Saved bed target, \(snapshot.targetLabel). Open sleepypod for current controls.")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.assignment).font(.headline)
                Text("Target \(snapshot.targetLabel)").font(.body)
                checked(snapshot).font(.caption)
            }.lineLimit(1)
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                primary(snapshot).frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Saved wake plan", systemImage: "alarm").font(.caption.bold())
                    if let wake = snapshot.savedWake(at: entry.date) {
                        Text("\(wake.side.capitalized) · \(wake.timeLabel)").font(.headline)
                        Text(wake.dateLabel).font(.caption)
                        if let warm = wake.warmingLabel { Text("Warming at \(warm)").font(.caption) }
                    } else if snapshot.wake != nil {
                        Text("Wake time passed. Open to refresh.").font(.caption)
                    } else { Text(snapshot.nextWake).font(.caption).lineLimit(5) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        default: primary(snapshot)
        } }
    }
    private func accessibleStatus(_ snapshot: BedWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Saved \(snapshot.zones.count == 2 ? "L/R" : snapshot.zones[0].id == "left" ? "L" : "R")")
                .font(.caption2).lineLimit(1).minimumScaleFactor(0.5)
            Text(snapshot.targetLabel.replacingOccurrences(of: "°F / ", with: "/"))
                .font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.5)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Saved bed target, \(snapshot.targetLabel), \(snapshot.assignment). Last checked \(snapshot.checkedAt.formatted()). Open sleepypod to refresh.")
    }
    private func primary(_ snapshot: BedWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Bed target", systemImage: "bed.double").font(.caption.bold()).widgetAccentable()
            Text(snapshot.targetLabel).font(showsBackground ? .largeTitle.bold() : .system(.largeTitle, design: .rounded).bold())
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(snapshot.assignment).font(.caption).lineLimit(2)
            Spacer(minLength: 0)
            checked(snapshot).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func checked(_ snapshot: BedWidgetSnapshot) -> Text {
        Text("Saved \(snapshot.checkedAt, style: .relative) ago")
    }
    @ViewBuilder private func savedWake(_ wake: BedRemoteWake, snapshot: BedWidgetSnapshot) -> some View {
        if textSize.isAccessibilitySize, family == .systemSmall || family == .systemMedium {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved \(wake.side == "left" ? "L" : "R")").font(.caption2).lineLimit(1).minimumScaleFactor(0.5)
                Text(wake.timeLabel).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.5)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Saved wake, \(wake.side) side, \(wake.dateLabel), \(wake.timeLabel), bed time zone \(wake.timeZone). Open sleepypod to confirm.")
        }
        else if family == .accessoryInline { Text("Saved \(wake.side) wake: \(wake.timeLabel)") }
        else {
            VStack(alignment: family == .accessoryCircular ? .center : .leading, spacing: 5) {
                if family == .accessoryCircular { Text("Saved").font(.caption2) }
                else { Label("Saved wake", systemImage: "alarm").font(.caption.bold()).widgetAccentable() }
                Text(wake.timeLabel).font(family == .accessoryCircular ? .caption.bold() : .title.bold())
                    .minimumScaleFactor(0.8).lineLimit(1)
                if family != .accessoryCircular {
                    Text("\(wake.side.capitalized) · \(wake.dateLabel)").font(.caption).lineLimit(1)
                    if family == .systemSmall || family == .systemMedium {
                        checked(snapshot).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: family == .accessoryCircular ? .center : .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Saved wake, \(wake.side) side, \(wake.dateLabel), \(wake.timeLabel), bed time zone \(wake.timeZone). Open sleepypod to confirm.")
        }
    }
    @ViewBuilder private var unavailable: some View {
        if family == .accessoryInline { Text("Bed · open sleepypod to refresh") }
        else if textSize.isAccessibilitySize, family == .systemSmall || family == .systemMedium {
            Text("Open sleepypod").font(.caption2.bold()).lineLimit(2).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityLabel("Open sleepypod to refresh your bed status.")
        }
        else {
            VStack(alignment: family == .accessoryCircular ? .center : .leading, spacing: 6) {
                Image(systemName: "bed.double").widgetAccentable()
                Text(family == .accessoryCircular ? "Open" : "Open sleepypod").font(.headline).lineLimit(1).minimumScaleFactor(0.5)
                if family != .accessoryCircular { Text("Refresh your bed status.").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: family == .accessoryCircular ? .center : .leading)
        }
    }
}
