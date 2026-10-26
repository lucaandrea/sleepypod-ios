import SwiftUI
import UIKit

/// In-app delivery only. This deliberately does not use NotificationRelay or its external webhooks.
struct AlertForegroundBanner: View {
    @Environment(AlertInboxSession.self) private var session
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let model = session.workspace, let alert = model.visibleAnnouncements(at: context.date).first {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Label("New automation alert", systemImage: "bell").font(.headline)
                        Spacer(minLength: 8)
                        Button("Dismiss", systemImage: "xmark") { model.dismissAnnouncements() }.labelStyle(.iconOnly)
                    }
                    Text(alert.title).font(.subheadline).lineLimit(2)
                    Text("Read in Settings → Alerts").font(.caption).foregroundStyle(Theme.text2)
                }.padding(16).background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.text2.opacity(0.25)))
                    .padding(.horizontal, 16).accessibilityElement(children: .contain)
            }
        }.onChange(of: session.workspace?.announcementRevision) { _, _ in
            guard let model = session.workspace, let alert = model.visibleAnnouncements(at: .now).first else { return }
            UIAccessibility.post(notification: .announcement, argument: "Automation alert: \(alert.title). \(alert.message)")
        }
    }
}
