import SwiftUI

/// Shared restrictions are visible separately from the current person's own request.
struct PersonalQuietScreen: View {
    let model: PersonalQuietWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @State private var minutes = 60
    var body: some View {
        Form {
            Section {
                Label("Someone is resting", systemImage: "moon.zzz").font(.headline)
                Text("Ask the bed and connected routines to keep shared actions quiet for a while.")
                Text("Alarms and your temperature plan continue.").font(.footnote).foregroundStyle(Theme.text2)
            }
            status
            if let error = model.error {
                Section { Text(error).foregroundStyle(Theme.text1).accessibilityIdentifier("quiet.error") }
            }
            if model.pending != nil {
                Section {
                    Text("A request may have reached the Pod. Check its result before making another change.")
                    Button("Check saved result") { Task { await model.reconcile() } }
                        .disabled(model.busy || !model.enabled).accessibilityIdentifier("quiet.reconcile")
                } footer: { Text("Checking only reads the result. Your request is never resent automatically.") }
            }
            if let notice = model.notice {
                Section { Text(notice).accessibilityIdentifier("quiet.notice") }
            }
            if model.enabled {
                Section {
                    Picker("Duration", selection: $minutes) {
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                        Text("8 hours").tag(480)
                    }.disabled(!model.editable).accessibilityIdentifier("quiet.duration")
                    Button(model.currentPage?.mine.until == nil ? "Start my quiet time" : "Update my quiet time") {
                        Task { await model.change(minutes: minutes) }
                    }.disabled(!model.editable).accessibilityIdentifier("quiet.save")
                    if model.currentPage?.mine.until != nil {
                        Button("End my quiet request") { Task { await model.change(minutes: nil) } }
                            .disabled(!model.editable).accessibilityIdentifier("quiet.end")
                    }
                } header: { Text("Your quiet request") } footer: {
                    Text("Ending your request leaves anyone else’s quiet time in place. Changing the duration starts it from now.")
                }
            }
            Section {
                DisclosureGroup("What pauses—and what continues") {
                    Text("New base movements are withheld. Connected bedtime-light, shade and purifier routines pause when they receive the quiet signal.")
                    Text("Temperature schedules and wake alarms keep running. Audio and other home routines are not paused by this control.")
                    Text("A saved request confirms the Pod’s setting, not that every home device received it. Delivery can take a few seconds.")
                    Text("Movement already underway does not stop automatically. Use the base’s Stop control if needed.")
                }.accessibilityIdentifier("quiet.explanation")
            }
            Section {
                Button("Refresh quiet status") { Task { await model.refresh() } }
                    .disabled(model.busy || !model.enabled).accessibilityIdentifier("quiet.refresh")
            }
        }
        .privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Quiet time").navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            guard scenePhase == .active else { model.suspend(); return }
            await model.refresh()
            var elapsed = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                model.tick(); elapsed += 1
                if elapsed.isMultiple(of: 5) { await model.poll() }
            }
        }
        .onDisappear { model.suspend() }
    }
    @ViewBuilder private var status: some View {
        Section("On your Pod") {
            if model.fresh, let page = model.currentPage {
                Label(page.shared.paused ? "Quiet time requested" : "No quiet time requested",
                      systemImage: page.shared.paused ? "moon.fill" : "moon")
                    .font(.headline).accessibilityIdentifier("quiet.sharedState")
                if let until = page.shared.until { Text("Shared quiet time until \(time(until))").accessibilityIdentifier("quiet.sharedUntil") }
                Text(page.mine.until.map { "Your request ends \(time($0))" } ?? "You have no active quiet request.")
                    .foregroundStyle(Theme.text2).accessibilityIdentifier("quiet.mine")
                if page.shared.paused && page.mine.until != page.shared.until {
                    Text("Another person’s request keeps shared quiet time in place.").font(.footnote).foregroundStyle(Theme.text2)
                }
            } else if !model.enabled {
                Text("Quiet time is unavailable. Return to your personal account and refresh to check access.")
                    .accessibilityIdentifier("quiet.unavailable")
            } else if model.busy {
                ProgressView("Checking quiet status…").accessibilityIdentifier("quiet.loading")
            } else {
                Text("Quiet status needs a fresh check.").accessibilityIdentifier("quiet.stale")
                Text("Refresh before making a change.").font(.footnote).foregroundStyle(Theme.text2)
            }
        }
    }
    private func time(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}
