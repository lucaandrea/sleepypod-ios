import SwiftUI

struct LogsView: View {
    @State private var showSheet = false

    var body: some View {
        Button {
            Haptics.light()
            showSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.textSecondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("System Logs")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Theme.text1)
                    Text("View service activity")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .padding(16)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            LogsSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Logs Sheet

private struct LogsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            SystemLogsScreen()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
