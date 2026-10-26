import SwiftUI

struct AlertInboxScreen: View {
    @Environment(AlertInboxSession.self) private var session
    @State private var confirmSelection = false
    var example = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Automation alerts").font(.title3.bold())
                if example {
                    Text("SYNTHETIC EXAMPLE · these alerts are not from a controller. Changes stay in memory.").font(.footnote).foregroundStyle(Theme.amber)
                } else if APIBackend.current.isDemo {
                    NavigationLink("Explore a synthetic inbox") { ExampleAlertInboxScreen() }.accessibilityIdentifier("alerts.example")
                }
                Text("Opening this inbox does not mark alerts read. Delivery is available while the app is open; background push is not available. Wake alarms are separate.")
                    .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if let error = session.setupError { Text(error).foregroundStyle(Theme.amber) }
                if let model = session.workspace {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        status(model, at: context.date)
                    }
                    if let error = model.error { Text("Could not refresh alerts. \(error)").font(.footnote).foregroundStyle(Theme.amber) }
                    if let error = model.acknowledgmentError { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
                    if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("alerts.notice") }
                    Button("Refresh alerts") { Task { await model.refresh() } }.disabled(model.busy).accessibilityIdentifier("alerts.refresh")
                    if let identifiers = model.pendingAcknowledgment {
                        Text("Pending acknowledgment: \(identifiers.count) selected alerts.").font(.footnote)
                        Button("Retry selected acknowledgment") { Task { await model.retryAcknowledgment() } }
                            .disabled(model.busy || model.loadingOlder).accessibilityIdentifier("alerts.retry")
                    } else if !model.selected.isEmpty {
                        Button("Mark \(model.selected.count) selected read") { confirmSelection = true }
                            .disabled(model.busy || model.loadingOlder).accessibilityIdentifier("alerts.acknowledge")
                    }
                    if model.latest != nil && model.items.isEmpty {
                        Text(model.latest?.delivery.foregroundInbox == true ? "No alerts in this inbox." : "Live alerts are unavailable in Demo.")
                            .foregroundStyle(Theme.text2).accessibilityIdentifier("alerts.empty")
                    }
                    ForEach(model.items) { item in
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            alert(item, model, at: context.date)
                        }
                    }
                    if model.nextBeforeId != nil {
                        Button(model.loadingOlder ? "Loading older alerts…" : "Load older alerts") { Task { await model.loadOlder() } }
                            .disabled(model.busy || model.loadingOlder).accessibilityIdentifier("alerts.older")
                    }
                }
            }.frame(maxWidth: 780, alignment: .leading).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Alerts").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Mark only the selected alerts read?", isPresented: $confirmSelection, titleVisibility: .visible) {
                Button("Mark selected read") { Task { await session.workspace?.acknowledgeSelection() } }.accessibilityIdentifier("alerts.confirm")
                Button("Cancel", role: .cancel) {}
            } message: { Text("New alerts arriving later remain unread.") }
    }
    @ViewBuilder private func status(_ model: AlertInboxWorkspace, at date: Date) -> some View {
        if let count = model.unreadCount(at: date) {
            Text("\(count) unread · live inbox").font(.headline).accessibilityIdentifier("alerts.count")
        } else if model.latest != nil {
            Text(model.latest?.delivery.foregroundInbox == true ? "Earlier successful check · refresh for current status" : "Live delivery unavailable")
                .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("alerts.status")
        } else { Text(model.busy ? "Loading alerts…" : "Inbox unavailable").foregroundStyle(Theme.text2) }
    }
    private func alert(_ item: AutomationAlert, _ model: AlertInboxWorkspace, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.headline)
            Text(item.message).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(Date(timeIntervalSince1970: Double(item.createdAt) / 1000).formatted(date: .abbreviated, time: .shortened))
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
            Text(state(item, at: model.serverTime(at: date))).font(.caption).foregroundStyle(Theme.text2)
            if item.acknowledgedAt == nil {
                Toggle("Select alert", isOn: Binding(get: { model.selected.contains(item.id) }, set: { selected in
                    if selected { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
                })).disabled(model.latest?.delivery.foregroundInbox != true || model.pendingAcknowledgment != nil || (!model.selected.contains(item.id) && model.selected.count >= 50))
                    .accessibilityIdentifier("alerts.select.\(item.id)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
    private func state(_ item: AutomationAlert, at time: Double?) -> String {
        if item.acknowledgedAt != nil { return "Read" }
        guard let time else { return "Unread at last check · current expiry unavailable" }
        return item.isUnread(at: time) ? "Unread" : "Expired · history only"
    }
}

struct AlertInboxLink: View {
    @Environment(AlertInboxSession.self) private var session
    var tile = false
    var body: some View {
        NavigationLink { AlertInboxScreen() } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                SettingsRow("Alerts", icon: "bell", tile: tile, chevron: true) {
                    if let count = session.workspace?.unreadCount(at: context.date), count > 0 { RowValue(String(count), mono: true) }
                }
            }
        }.accessibilityIdentifier("alerts.open")
    }
}
