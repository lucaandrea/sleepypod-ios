import SwiftUI

struct PhoneBackupAlarmView: View {
    let plan: NextAlarmState?
    let receivedAt: Date?
    let ownerScope: String?
    let canEdit: Bool
    @State private var backup = BackupAlarmCoordinator.shared
    @State private var confirmReplacement = false
    @State private var replacement: ReviewedBackup?
    @State private var reviewMessage: String?
    private struct ReviewedBackup {
        let plan: NextAlarmState
        let receivedAt: Date?
        let owner: String?
    }
    private var matches: Bool {
        guard let record = backup.record, let plan else { return false }
        return record.side == plan.side && plan.state == "scheduled" && record.at == plan.alarm.flatMap { NextAlarmState.instant($0.at) }
    }
    private var eligible: Bool {
        guard canEdit, let ownerScope, ownerScope == BackupAlarmCoordinator.ownerScope(), let plan else { return false }
        return (try? BackupAlarmPolicy.candidate(plan, receivedAt: receivedAt, now: .now)) != nil
    }
    private var confirmed: Bool { matches && backup.systemState == "scheduled" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Phone backup", systemImage: "iphone.radiowaves.left.and.right").font(.headline)
            if APIBackend.current.isDemo {
                Text("Connect to your Pod to add a one-time system alarm on this device. Practice mode never schedules a real alert.")
                    .font(.subheadline).foregroundStyle(Theme.text2)
            } else {
                if let record = backup.record {
                    Text("\(record.side.rawValue.capitalized) · \(record.at.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline.weight(.semibold))
                    Text(status).font(.subheadline).foregroundStyle(matches && backup.systemState == "scheduled" ? Theme.text2 : Theme.amber)
                    if let checked = backup.checkedAt { Text("Checked on this device \(checked.formatted(date: .omitted, time: .shortened)).") .font(.caption).foregroundStyle(Theme.text2) }
                } else { Text("No verified backup on this device.").font(.subheadline).foregroundStyle(Theme.text2) }
                Text("One wake-up only. The system alert can sound through Silent mode and Focus. Other Clock alarms stay unchanged. If the Pod plan changes, review this backup too.")
                    .font(.footnote).foregroundStyle(Theme.text2)
                if let plan, let alarm = plan.alarm {
                    Button(backup.record == nil ? "Add backup for \(DisplayTime.clock(alarm.time))" : confirmed ? "Verify this backup" : "Replace phone backup") {
                        if confirmed { backup.refresh() }
                        else if backup.record != nil {
                            reviewMessage = nil
                            replacement = .init(plan: plan, receivedAt: receivedAt, owner: ownerScope)
                            confirmReplacement = true
                        } else { Task { await backup.schedule(plan: plan, receivedAt: receivedAt, expectedOwner: ownerScope) } }
                    }.disabled(backup.busy || !eligible).frame(minHeight: 44).accessibilityIdentifier("wake.backup.add")
                }
                if backup.record != nil || backup.message != nil {
                    Button("Remove phone backup", role: .destructive) { backup.cancel() }
                        .disabled(backup.busy).frame(minHeight: 44).accessibilityIdentifier("wake.backup.remove")
                }
                Button("Check phone alarm", systemImage: "arrow.clockwise") { backup.refresh() }
                    .disabled(backup.busy).frame(minHeight: 44)
                if backup.busy { ProgressView("Checking phone alarm…") }
                if let message = backup.message { Text(message).font(.footnote).foregroundStyle(Theme.text2) }
                if let reviewMessage { Text(reviewMessage).font(.footnote).foregroundStyle(Theme.amber) }
            }
        }
        .task { if !APIBackend.current.isDemo { backup.refresh() } }
        .confirmationDialog("Replace the saved phone backup?", isPresented: $confirmReplacement, presenting: replacement) { reviewed in
            Button("Replace backup") {
                guard plan?.revision == reviewed.plan.revision else {
                    reviewMessage = "The Pod plan changed. Review it before replacing your backup."
                    return
                }
                Task { await backup.schedule(plan: reviewed.plan, receivedAt: reviewed.receivedAt, expectedOwner: reviewed.owner) }
            }
        } message: { reviewed in
            Text("Replace it with \(reviewed.plan.alarm.map { reviewed.plan.label($0.at) } ?? "the reviewed wake time")? The previous app-owned alarm is removed first. A failure may leave no phone backup; check the result here.")
        }
    }
    private var status: String {
        if !matches { return "This backup differs from the displayed Pod plan, or that plan is unavailable. It has not been changed." }
        switch backup.systemState {
        case "scheduled": return "iOS confirms it is scheduled. Physical alert delivery has not been tested."
        case "missing": return "iOS no longer lists this backup. Add it again if needed."
        case "alerting": return "The system reports that this backup is alerting."
        default: return "Backup not confirmed. Check the phone alarm before relying on it."
        }
    }
}

/// Reconcile the stored ID on foreground and identity changes, even outside Schedule.
struct BackupAlarmLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @AppStorage("apiBackend") private var backend = ""
    @AppStorage("podURL") private var endpoint = ""
    @AppStorage("podIPAddress") private var address = ""
    @AppStorage("ownerConnectionRevision") private var owner = ""
    @AppStorage("household.boundaryRevision") private var household = ""
    func body(content: Content) -> some View {
        content.task(id: [backend, endpoint, address, owner, household, String(describing: phase)]) {
            guard phase == .active, !APIBackend.current.isDemo else { return }
            while !Task.isCancelled {
                BackupAlarmCoordinator.shared.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
}
