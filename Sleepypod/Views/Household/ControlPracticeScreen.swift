import SwiftUI

/// All displayed values belong to this view's example; no live workspace is injected.
struct ControlPracticeScreen: View {
    var guideURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var example = ControlPractice()
    @AccessibilityFocusState private var lessonFocused: Bool
    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    Text("Try the bed controls").font(.title2.bold())
                    Text("Practice three everyday actions with example settings. Your bed and real alarms stay unchanged.")
                        .foregroundStyle(Theme.text1)
                    Picker("Lesson", selection: Binding(get: { example.lesson }, set: { example.send(.lesson($0)) })) {
                        ForEach(ControlPractice.Lesson.allCases) { lesson in
                            Label(lesson.title, systemImage: example.completed(lesson) ? "checkmark.circle" : lesson.symbol).tag(lesson)
                        }
                    }.accessibilityIdentifier("practice.lesson")
                }.id("practice.top")
                switch example.lesson {
                case .temperature: temperature
                case .wake: wake
                case .stop: stop
                }
                Section {
                    Text("\(example.completedCount) of 3 actions practiced").accessibilityIdentifier("practice.progress")
                    if example.lesson != .stop {
                        Button(example.completed(example.lesson) ? "Next lesson" : "Skip to next lesson") {
                            example.send(.lesson(example.lesson == .temperature ? .wake : .stop))
                        }.accessibilityIdentifier("practice.next")
                    } else { Button("Finish practice") { dismiss() }.accessibilityIdentifier("practice.finish") }
                    Button("Restart practice") { example.send(.reset); proxy.scrollTo("practice.top", anchor: .top) }
                        .accessibilityIdentifier("practice.reset")
                    if let guideURL { Link("Open the illustrated guide", destination: guideURL) }
                } footer: {
                    Text("Practice choices disappear when you leave. To join the household, use your personal invitation. You never need the owner’s connection key.")
                        .foregroundStyle(Theme.text1)
                }
            }
            .scrollContentBackground(.hidden).background(Theme.background).accessibilityIdentifier("practice.form")
            .navigationTitle("Practice").navigationBarTitleDisplayMode(.inline)
            .onChange(of: example.lesson) { proxy.scrollTo("practice.top", anchor: .top); lessonFocused = true }
        }
    }
    private var temperature: some View {
        Section {
            heading("Try a cooler target.", symbol: "thermometer.medium")
            Text("A cooler or warmer tap requests a new target right away. In the real app, the measured water temperature can take time to catch up.")
                .foregroundStyle(Theme.text1)
            HStack(alignment: .center, spacing: 20) {
                Image(systemName: "bed.double").font(.largeTitle).foregroundStyle(Theme.cool).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Example side").font(.headline)
                    Text("\(example.requestedTargetF)°F").font(.largeTitle.bold()).monospacedDigit()
                        .accessibilityIdentifier("practice.requestedTarget")
                    Text("Requested practice target").font(.footnote).foregroundStyle(Theme.text1)
                }
            }.padding(.vertical, 8)
            Button("1°F cooler", systemImage: "minus") { example.send(.step(-1)) }
                .disabled(example.requestedTargetF <= 65).accessibilityIdentifier("practice.cooler")
            Button("1°F warmer", systemImage: "plus") { example.send(.step(1)) }
                .disabled(example.requestedTargetF >= 90).accessibilityIdentifier("practice.warmer")
            feedback(example.completed(.temperature) ? "Example request changed to \(example.requestedTargetF)°F. Your real bed did not change."
                     : "Try tapping one degree cooler.")
        }
    }
    private var wake: some View {
        Section {
            heading("Give tomorrow a later start.", symbol: "alarm")
            Text("This example normally wakes at 07:00. Move tomorrow’s example to a later time, review it, then save. The regular week stays the same.")
                .foregroundStyle(Theme.text1)
            DatePicker("Tomorrow’s practice wake time", selection: wakeDate, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!).accessibilityIdentifier("practice.wakeTime")
            Button("Review practice alarm") { example.send(.reviewWake) }.disabled(example.draftWake == example.savedWake)
                .accessibilityIdentifier("practice.review")
            if let reviewed = example.reviewedWake {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tomorrow’s example").font(.headline)
                    Label("Warming starts at \(ControlPractice.warmingTime(reviewed) ?? "—")", systemImage: "thermometer.medium")
                    Label("Vibration at \(reviewed) · 20 seconds", systemImage: "waveform")
                    Text("Regular week: still 07:00").foregroundStyle(Theme.text1)
                    Text("Phone alarms and wake-up lights are separate. A Pod change alone does not confirm that they changed.")
                        .font(.footnote).foregroundStyle(Theme.text1)
                }.fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("practice.wakeReview")
                Button("Save practice alarm") { example.send(.saveWake) }.accessibilityIdentifier("practice.save")
            }
            feedback(example.completed(.wake) ? "Tomorrow’s example is saved for \(example.savedWake). No real alarm changed."
                     : "Saved example: \(example.savedWake). Choose a time and review it before saving.")
        }
    }
    private var stop: some View {
        Section {
            heading("Know how to stop each action.", symbol: "power")
            Text("Power off stops heating and cooling. Look for the power symbol in the bed controls. Vibration has its own Stop. Neither deletes the next scheduled alarm.")
                .foregroundStyle(Theme.text1)
            Label("Example temperature: \(example.temperatureOn ? "On" : "Off")", systemImage: "thermometer.medium")
                .accessibilityIdentifier("practice.temperatureState")
            Button("Power off", systemImage: "power") { example.send(.stopTemperature) }.disabled(!example.temperatureOn)
                .accessibilityHint("Stops heating and cooling only in this practice example.")
                .accessibilityIdentifier("practice.stopTemperature")
            Label("Example vibration: \(example.vibrationOn ? "Playing" : "Stopped")", systemImage: "waveform")
                .accessibilityIdentifier("practice.vibrationState")
            Button("Stop vibration", systemImage: "stop.circle") { example.send(.stopVibration) }.disabled(!example.vibrationOn)
                .accessibilityHint("Stops vibration only in this practice example.")
                .accessibilityIdentifier("practice.stopVibration")
            Label("Next example alarm: \(example.savedWake) · still saved", systemImage: "alarm")
                .accessibilityIdentifier("practice.nextAlarm")
            feedback(example.completed(.stop) ? "Both example actions stopped. Your real bed is unchanged."
                     : "The next scheduled alarm stays saved when you power off or stop vibration.")
        }
    }
    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.headline).accessibilityAddTraits(.isHeader)
            .accessibilityFocused($lessonFocused).accessibilityIdentifier("practice.heading")
    }
    private func feedback(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Theme.text1).accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("practice.feedback")
    }
    /// A fixed date in UTC lets the native time picker edit the same HH:mm example used on the web.
    private var wakeDate: Binding<Date> {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return Binding(get: {
            calendar.date(from: DateComponents(year: 2001, month: 1, day: 1,
                                               hour: Int(example.draftWake.prefix(2)), minute: Int(example.draftWake.suffix(2))))!
        }, set: { value in
            let time = calendar.dateComponents([.hour, .minute], from: value)
            example.send(.editWake(String(format: "%02d:%02d", time.hour ?? 8, time.minute ?? 0)))
        })
    }
}
