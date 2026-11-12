import SwiftUI

/// Quiet, large native controls keep the selected physical scope visible beside every overnight action.
struct BedControlsView: View {
    private enum Destination: String, Hashable { case wake, recording }
    @Environment(RecordingController.self) private var recording
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Destination] = []

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--bed-remote-example"), let index = arguments.firstIndex(of: "--example-destination"),
           arguments.indices.contains(index + 1), let destination = Destination(rawValue: arguments[index + 1]) {
            _path = State(initialValue: [destination])
        }
        #endif
    }
    var body: some View {
        let bed = recording.bed
        NavigationStack(path: $path) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let snapshot = bed.snapshot {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.assignment).font(.headline)
                                Text(snapshot.person).font(.footnote).foregroundStyle(.secondary)
                            }
                            temperature(snapshot, at: timeline.date)
                            Button { Task { await bed.stop(vibration: false) } } label: {
                                Label("Stop temperature", systemImage: "power").font(.footnote)
                                    .frame(minHeight: 44)
                            }
                            .disabled(!bed.canStop(at: timeline.date))
                            .accessibilityIdentifier("watch.stopTemperature")
                            readings(snapshot, at: timeline.date)
                            NavigationLink(value: Destination.wake) { Label("Next wake", systemImage: "alarm") }
                            .accessibilityIdentifier("watch.nextWake")
                            if let explanation = snapshot.explanation { Text(explanation).font(.footnote).foregroundStyle(.secondary) }
                        } else {
                            Label("Your bed", systemImage: "bed.double").font(.headline)
                            Text("Temperature, Stop and your next wake plan, through your paired iPhone.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(bed.message).font(.footnote).accessibilityIdentifier("watch.message")
                        Button(bed.refreshing ? "Refreshing…" : "Refresh bed") { Task { await bed.refresh() } }
                            .disabled(bed.refreshing || bed.adjusting || bed.stopping)
                            .accessibilityIdentifier("watch.refresh")
                        NavigationLink("Research recording", value: Destination.recording)
                            .font(.footnote)
                    }
                    .padding(.horizontal, 2)
                }
            }
            .navigationTitle(bed.isExample ? "Bed preview" : "Bed")
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .wake: WatchWakeView()
                case .recording: RecorderView().navigationTitle("Recording")
                }
            }
        }
        .transformEnvironment(\.dynamicTypeSize) { size in
            #if DEBUG
            if bed.isExample && ProcessInfo.processInfo.arguments.contains("--example-large-text") { size = .accessibility3 }
            #endif
        }
        .task { await bed.refresh() }
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await bed.refresh() } } }
    }
    @ViewBuilder private func temperature(_ snapshot: BedRemoteSnapshot, at now: Date) -> some View {
        if let target = snapshot.targetF {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    adjustment(target, delta: -1, at: now)
                    targetLabel(target)
                    adjustment(target, delta: 1, at: now)
                }
                VStack(spacing: 6) {
                    targetLabel(target)
                    HStack {
                        adjustment(target, delta: -1, at: now)
                        Spacer()
                        adjustment(target, delta: 1, at: now)
                    }
                }
            }
            .accessibilityIdentifier("watch.temperature")
        } else {
            Text(snapshot.zones.count > 1 ? "Different or missing targets" : "Target unavailable").font(.body)
            Text("Check the selected side on iPhone, then refresh.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func targetLabel(_ target: Int) -> some View {
        Text("\(target)°F").font(.title2.weight(.semibold)).monospacedDigit().fixedSize()
            .accessibilityLabel("Requested temperature \(target) degrees Fahrenheit")
    }
    private func adjustment(_ target: Int, delta: Int, at now: Date) -> some View {
        Button { Task { await recording.bed.setTemperature(target + delta) } } label: {
            Image(systemName: delta < 0 ? "minus" : "plus")
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(delta < 0 ? "Cooler by one degree Fahrenheit" : "Warmer by one degree Fahrenheit")
        .disabled(!recording.bed.canAdjust(at: now) || !(55...110).contains(target + delta))
    }
    private func readings(_ snapshot: BedRemoteSnapshot, at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if snapshot.readingsFresh(at: now), snapshot.isCurrent(at: now) {
                ForEach(snapshot.zones) { zone in
                    if let measured = zone.measuredF {
                        Text("\(zone.id.capitalized) water \(measured, format: .number.precision(.fractionLength(0)))°F")
                    }
                }
                Text("Updated \(snapshot.receivedAt, style: .relative) ago")
            } else { Text("Readings expired · refresh bed") }
        }.font(.footnote).foregroundStyle(.secondary)
    }
}

/// Read the live model while this destination is open; a navigation push cannot freeze an old lease.
private struct WatchWakeView: View {
    @Environment(RecordingController.self) private var recording
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let bed = recording.bed
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let snapshot = bed.snapshot {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.assignment).font(.headline)
                            Text(snapshot.person).font(.footnote).foregroundStyle(.secondary)
                            if bed.isExample { Text("Preview · no bed commands").font(.footnote).foregroundStyle(.secondary) }
                        }
                        Text(snapshot.nextAlarm).font(.body)
                        Text(snapshot.isCurrent(at: timeline.date) ? "Current plan when refreshed." : "This plan has expired. Refresh to check it again.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Stop vibration") { Task { await bed.stop(vibration: true) } }
                            .disabled(!bed.canStop(at: timeline.date))
                            .accessibilityIdentifier("watch.stopVibration")
                    } else { Text(bed.message).font(.body) }
                    Button(bed.refreshing ? "Refreshing…" : "Refresh bed") { Task { await bed.refresh() } }
                        .disabled(bed.refreshing || bed.adjusting || bed.stopping)
                    Text("Change the wake plan on iPhone.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("Next wake")
    }
}
