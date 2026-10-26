import SwiftUI

struct NativeCurveLibraryScreen: View {
    @Environment(CurveWorkspace.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedule
    @State private var editing: CurveDraft?
    @State private var running: RunOnceDraft?
    @State private var deleting: PodCurve?
    @State private var toggling: CurveDraft?
    @State private var applying: PodCurve?
    @State private var showAI = false
    private var timeZone: TimeZone { TimeZone(identifier: settings.timeZone) ?? .current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !model.loaded && model.loading { ProgressView("Loading curves…") }
                CurveFeedback()
                ForEach(Side.allCases) { side in
                    if let session = model.sessions[side] {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(settings.sideName(for: side)).font(.headline)
                            RunOnceActiveBanner(session: session, onCancel: { Task { await model.cancel(side) } })
                        }
                    }
                }
                if model.curves.isEmpty && model.loaded {
                    ContentUnavailableView("Your curves", systemImage: "waveform.path", description: Text("Create a temperature curve, then choose when it runs."))
                }
                ForEach(model.curves) { curve in curveCard(curve) }
                if model.loaded {
                    Button("New curve", systemImage: "plus") { editing = CurveDraft() }
                        .buttonStyle(.borderedProminent).foregroundStyle(Theme.background).accessibilityIdentifier("curve.new").disabled(model.saving)
                    Text(APIBackend.current.isDemo ? "DEMO · curves and run-once sessions are simulated" : "Times follow \(settings.timeZone).")
                        .font(.footnote).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
        }.background(Theme.background).navigationTitle("Curves").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New curve", systemImage: "plus") { editing = CurveDraft() }
                    Button("AI curve designer", systemImage: "wand.and.stars") { showAI = true }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Curve options")
            }
        }
        .task { await model.refresh() }.refreshable { await model.refresh() }
        .sheet(item: $editing) { NativeCurveEditor(initial: $0) }
        .sheet(item: $running) { RunOnceReview(initial: $0) }
        .sheet(isPresented: $showAI) { AICurvePromptView() }
        .confirmationDialog("Delete curve?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { curve in
            Button("Delete \(curve.name)", role: .destructive) { Task { _ = await model.delete(curve); await schedule.fetchSchedules() } }
        } message: { curve in Text(curve.active == true ? "Its assigned days will stop running. Alarms stay as scheduled." : "This removes the saved curve. Alarms stay as scheduled.") }
        .confirmationDialog("Move shared days?", isPresented: Binding(get: { toggling != nil }, set: { if !$0 { toggling = nil } }), presenting: toggling) { draft in
            Button("Move days and turn on") { saveToggle(draft) }
        } message: { draft in Text(CurveMoveText.describe(model.moves(draft), settings: settings)) }
        .confirmationDialog("Apply saved curve?", isPresented: Binding(get: { applying != nil }, set: { if !$0 { applying = nil } }), presenting: applying) { curve in
            Button("Apply curve") { Task {
                let template = CurveTemplate(name: curve.name, points: curve.points.mapValues { Int($0.rounded()) }, bedtime: curve.bedtime, wake: curve.wake, reasoning: curve.notes)
                if await schedule.applyTemplate(template) { model.notice = "Curve applied." } else { model.error = schedule.error }
            } }
        } message: { _ in Text("Replace temperature and power schedules for \(schedule.selectedSide.sides.map { settings.sideName(for: $0) }.joined(separator: " and ")) on \(CurveDays.label(Array(schedule.selectedDays))). Alarms keep their current settings.") }
    }
    private func saveToggle(_ draft: CurveDraft) {
        let moves = model.moves(draft)
        Task { _ = await model.save(draft, reviewed: moves); await schedule.fetchSchedules() }
    }
    private func curveCard(_ curve: PodCurve) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Button { editing = CurveDraft(curve: curve) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(curve.name).font(.headline)
                        Text("\(DisplayTime.clock(curve.bedtime)) → \(DisplayTime.clock(curve.wake))")
                            .font(.mono(13, relativeTo: .footnote)).foregroundStyle(Theme.text2)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("curve.edit.\(curve.id)")
                if model.supportsAssignments {
                    Toggle("Run \(curve.name)", isOn: Binding(get: { curve.active == true }, set: { enabled in
                        var draft = CurveDraft(curve: curve); draft.active = enabled
                        if !model.moves(draft).isEmpty { toggling = draft } else { saveToggle(draft) }
                    })).labelsHidden().fixedSize().tint(Theme.green).disabled(model.saving || !model.loaded || curve.days?.isEmpty != false)
                }
            }
            if let days = curve.days {
                ForEach(Side.allCases) { side in
                    if !days[side].isEmpty {
                        Text("\(settings.sideName(for: side)) · \(CurveDays.label(days[side]))\(curve.active == true ? "" : " · Paused")")
                            .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if days.isEmpty { Text("Saved · no days assigned").font(.footnote).foregroundStyle(Theme.text3) }
            }
            TemperatureCurve(points: curve.ordered.map { RunOnceSetPoint(time: $0.time, temperature: $0.temperature) }, bedtime: curve.bedtime, wake: curve.wake, compact: true)
            if !curve.notes.isEmpty { Text(curve.notes).font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true) }
            ViewThatFits(in: .horizontal) { actions(curve, vertical: false); actions(curve, vertical: true) }
        }.cardStyle()
    }
    private func actions(_ curve: PodCurve, vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            Button("Run once", systemImage: "play") { running = RunOnceDraft(curve: curve, side: schedule.selectedSide.primarySide, timeZone: timeZone) }
                .accessibilityIdentifier("curve.run.\(curve.id)")
            Button("Duplicate", systemImage: "square.on.square") { editing = CurveDraft(curve: curve, copy: true) }
            Menu {
                if !model.supportsAssignments { Button("Apply to selected days") { applying = curve } }
                Button("Edit") { editing = CurveDraft(curve: curve) }
                Button("Delete", role: .destructive) { deleting = curve }
            } label: { Label("More", systemImage: "ellipsis") }.accessibilityLabel("More for \(curve.name)")
        }.font(.subheadline).buttonStyle(.plain).disabled(model.saving || !model.loaded)
    }
}

private struct CurveFeedback: View {
    @Environment(CurveWorkspace.self) private var model
    var body: some View {
        if let error = model.error {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                Button("Reload curves") { Task { await model.refresh() } }.disabled(model.loading || model.saving)
            }.font(.footnote)
        }
        if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true) }
    }
}
private enum CurveMoveText {
    @MainActor static func describe(_ moves: [CurveMove], settings: SettingsManager) -> String {
        moves.map { "\($0.name): \(settings.sideName(for: $0.side)) · \(CurveDays.label($0.days))\($0.deactivated ? ". This curve will pause." : "")" }.joined(separator: "\n")
    }
}

struct NativeCurveEditor: View {
    @Environment(CurveWorkspace.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(ScheduleManager.self) private var schedule
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var draft: CurveDraft
    @State private var pointEditor: CurvePoint?
    @State private var confirmMoves = false
    @FocusState private var nameFocused: Bool
    init(initial: CurveDraft) { _draft = State(initialValue: initial) }
    private var timeZone: TimeZone { TimeZone(identifier: settings.timeZone) ?? .current }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupedCard {
                        TextField("Curve name", text: $draft.name).textInputAutocapitalization(.sentences).focused($nameFocused).padding(16)
                        if model.supportsAssignments { Toggle("Run on assigned days", isOn: $draft.active).tint(Theme.green).padding(16) }
                    }
                    if model.supportsAssignments {
                        ForEach(Side.allCases) { side in
                            CurveDayPicker(title: settings.sideName(for: side), selected: Binding(get: { Set(draft.days[side]) }, set: { selected in draft.days[side] = DayOfWeek.weekdays.filter { selected.contains($0) } }))
                        }
                        if draft.days.isEmpty { Text("Without days, this curve is saved without running.").font(.footnote).foregroundStyle(Theme.text2) }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Eyebrow("TIMES")
                        clockField("Bedtime", value: clock(draft.bedtime) { draft.rebase(bedtime: $0, wake: draft.wake) })
                        clockField("Wake up", value: clock(draft.wake) { draft.rebase(bedtime: draft.bedtime, wake: $0) })
                        Text(settings.timeZone).font(.footnote).foregroundStyle(Theme.text3)
                        if model.supportsAssignments {
                            Text("After schedule ends").font(.subheadline).foregroundStyle(Theme.text2)
                            Picker("After schedule ends", selection: $draft.endAction) {
                                ForEach(ScheduleEndAction.allCases, id: \.self) { Text($0.label).tag($0) }
                            }.pickerStyle(.menu).accessibilityIdentifier("curve.endAction")
                        }
                    }.cardStyle()
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow("PRESET")
                        temperatureRange("Coolest", value: Binding(get: { draft.coolest }, set: { draft.setBounds(coolest: $0, warmest: draft.warmest) }), range: 55...draft.warmest)
                        temperatureRange("Warmest", value: Binding(get: { draft.warmest }, set: { draft.setBounds(coolest: draft.coolest, warmest: $0) }), range: draft.coolest...110)
                        Menu("Choose a preset", systemImage: "waveform.path") {
                            Button("Hot Sleeper") { draft.generate(.cool) }
                            Button("Balanced") { draft.generate(.balanced) }
                            Button("Cold Sleeper") { draft.generate(.warm) }
                        }.buttonStyle(.bordered).accessibilityIdentifier("curve.preset")
                    }.cardStyle()
                    if !draft.points.isEmpty {
                        EditableTemperatureCurve(points: $draft.points) { pointEditor = $0 }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow("SET POINTS")
                        ForEach(draft.ordered) { point in
                            HStack(alignment: .center) {
                                Button { pointEditor = point } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(DisplayTime.clock(point.time)).font(.mono(16, relativeTo: .body))
                                        Text(TemperatureDisplay.degrees.text(Int(point.temperature.rounded()), unit: settings.temperatureFormat.degreeUnit, includeUnit: true))
                                            .foregroundStyle(TempColor.forScheduled(Int(point.temperature.rounded())))
                                        if point.id == draft.ordered.first?.id { Text("Power on").font(.caption).foregroundStyle(Theme.text3) }
                                        if model.supportsAssignments && point.id == draft.ordered.last?.id { Text(draft.endAction.label).font(.caption).foregroundStyle(Theme.text3) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Edit set point at \(point.time)")
                                Button("Delete", systemImage: "minus.circle", role: .destructive) { draft.points.removeAll { $0.id == point.id } }
                                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).accessibilityLabel("Delete set point at \(point.time)")
                            }.padding(.vertical, 6)
                        }
                        Button("Add set point", systemImage: "plus") {
                            let occupied = Set(draft.points.map(\.time))
                            let free = (0..<1440).map { CurvePoint.clock((draft.ordered.last?.minutes ?? 1320) + 30 + $0) }.first { !occupied.contains($0) } ?? "12:00"
                            pointEditor = CurvePoint(time: free, temperature: 75)
                        }.disabled(draft.points.count >= 48)
                    }.cardStyle()
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow("NOTES")
                        TextField("What would you like to try?", text: $draft.notes, axis: .vertical).lineLimit(3...8).accessibilityLabel("Curve notes")
                        Text("\(draft.notes.count)/1,000").font(.caption).foregroundStyle(Theme.text3)
                    }.cardStyle()
                    if let validation = draft.validation { Text(validation).font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true) }
                    CurveFeedback()
                }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
            }.accessibilityIdentifier("curve.editor.scroll").scrollDismissesKeyboard(.interactively).background(Theme.background).environment(\.timeZone, timeZone)
            .navigationTitle(draft.original == nil ? "New curve" : "Edit curve").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    nameFocused = false
                    if model.moves(draft).isEmpty { save() } else { confirmMoves = true }
                }.disabled(draft.validation != nil || !model.loaded || model.saving) }
            }.interactiveDismissDisabled(model.saving)
            .task { if !model.loaded { await model.refresh() } }
            .sheet(item: $pointEditor) { point in
                CurvePointEditor(initial: point, occupied: Set(draft.points.filter { $0.id != point.id }.map(\.time)), timeZone: timeZone) { updated in
                    if let index = draft.points.firstIndex(where: { $0.id == updated.id }) { draft.points[index] = updated }
                    else { draft.points.append(updated) }
                }
            }
            .confirmationDialog("Move shared days?", isPresented: $confirmMoves) {
                Button("Move days and save") { save() }
            } message: { Text(CurveMoveText.describe(model.moves(draft), settings: settings)) }
        }
    }
    private func save() {
        let reviewed = model.moves(draft)
        Task { if await model.save(draft, reviewed: reviewed) { await schedule.fetchSchedules(); dismiss() } }
    }
    private func clock(_ value: String, set: @escaping @MainActor @Sendable (String) -> Void) -> Binding<Date> { WallClock.binding(value, timeZone: timeZone, set: set) }
    @ViewBuilder private func clockField(_ title: String, value: Binding<Date>) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).foregroundStyle(Theme.text2)
                DatePicker(title, selection: value, displayedComponents: .hourAndMinute).labelsHidden()
            }
        } else { DatePicker(title, selection: value, displayedComponents: .hourAndMinute) }
    }
    private func temperatureRange(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(Theme.text2)
            Stepper(TemperatureDisplay.degrees.text(value.wrappedValue, unit: settings.temperatureFormat.degreeUnit, includeUnit: true)) {
                value.wrappedValue = min(range.upperBound, TemperatureDisplay.degrees.step(value.wrappedValue, by: 1, unit: settings.temperatureFormat.degreeUnit))
            } onDecrement: {
                value.wrappedValue = max(range.lowerBound, TemperatureDisplay.degrees.step(value.wrappedValue, by: -1, unit: settings.temperatureFormat.degreeUnit))
            }
        }
    }
}

private struct CurveDayPicker: View {
    let title: String
    @Binding var selected: Set<DayOfWeek>
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Menu("Choose days") {
                Button("Every day") { selected = Set(DayOfWeek.weekdays) }
                Button("Weekdays") { selected = Set(DayOfWeek.weekdays.prefix(5)) }
                Button("Weekends") { selected = [.saturday, .sunday] }
                Button("None") { selected = [] }
            }.accessibilityLabel("Choose days for \(title)")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 140 : 76))], spacing: 8) {
                ForEach(DayOfWeek.weekdays) { day in
                    Button(String(day.displayName.prefix(3))) { if selected.contains(day) { selected.remove(day) } else { selected.insert(day) } }
                        .font(.body).frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selected.contains(day) ? Theme.background : Theme.text1)
                        .background(selected.contains(day) ? Theme.text1 : Theme.active, in: RoundedRectangle(cornerRadius: 9))
                        .buttonStyle(.plain).accessibilityLabel("\(title) \(day.displayName)")
                        .accessibilityAddTraits(selected.contains(day) ? .isSelected : [])
                }
            }
        }.cardStyle()
    }
}

private struct CurvePointEditor: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var point: CurvePoint
    let occupied: Set<String>
    let timeZone: TimeZone
    let save: (CurvePoint) -> Void
    init(initial: CurvePoint, occupied: Set<String>, timeZone: TimeZone, save: @escaping (CurvePoint) -> Void) {
        _point = State(initialValue: initial); self.occupied = occupied; self.timeZone = timeZone; self.save = save
    }
    var body: some View {
        NavigationStack {
            Form {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Time").foregroundStyle(Theme.text2)
                    DatePicker("Time", selection: WallClock.binding(point.time, timeZone: timeZone) { point.time = $0 }, displayedComponents: .hourAndMinute).labelsHidden()
                }
                Stepper(TemperatureDisplay.degrees.text(Int(point.temperature.rounded()), unit: settings.temperatureFormat.degreeUnit, includeUnit: true)) {
                    point.temperature = Double(TemperatureDisplay.degrees.step(Int(point.temperature.rounded()), by: 1, unit: settings.temperatureFormat.degreeUnit))
                } onDecrement: {
                    point.temperature = Double(TemperatureDisplay.degrees.step(Int(point.temperature.rounded()), by: -1, unit: settings.temperatureFormat.degreeUnit))
                }.accessibilityLabel("Set point temperature")
                if occupied.contains(point.time) { Text("There is already a set point at that time.").foregroundStyle(Theme.amber) }
            }.environment(\.timeZone, timeZone).navigationTitle("Set point").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { save(point); dismiss() }.disabled(occupied.contains(point.time)) }
                }
        }
    }
}
private enum WallClock {
    static func binding(_ value: String, timeZone: TimeZone, set: @escaping @MainActor @Sendable (String) -> Void) -> Binding<Date> {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let selectedCalendar = calendar
        return Binding(get: {
            let minutes = AlarmDraft.clockMinutes(value) ?? 0
            return selectedCalendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: minutes / 60, minute: minutes % 60)) ?? .now
        }, set: { date in
            // SwiftUI invokes this control's setter on the main thread.
            MainActor.assumeIsolated { set(CurvePoint.clock(selectedCalendar.component(.hour, from: date) * 60 + selectedCalendar.component(.minute, from: date))) }
        })
    }
}

struct RunOnceReview: View {
    @Environment(CurveWorkspace.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RunOnceDraft
    init(initial: RunOnceDraft) { _draft = State(initialValue: initial) }
    private var timeZone: TimeZone { TimeZone(identifier: settings.timeZone) ?? .current }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(draft.curve.name).font(.title2)
                    Picker("Side", selection: $draft.side) { ForEach(Side.allCases) { Text(settings.sideName(for: $0)).tag($0) } }.pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Until").foregroundStyle(Theme.text2)
                        DatePicker("Until", selection: WallClock.binding(draft.wake, timeZone: timeZone) { draft.setWake($0) }, displayedComponents: .hourAndMinute).labelsHidden()
                    }
                    Text(settings.timeZone).font(.footnote).foregroundStyle(Theme.text3)
                    TemperatureCurve(points: draft.points.map { RunOnceSetPoint(time: $0.time, temperature: $0.temperature) }, bedtime: draft.points.first?.time ?? "22:00", wake: draft.wake).cardStyle()
                    Text("Starting powers this side on and applies the first temperature immediately. It replaces any active run-once session. Cancelling resumes the recurring schedule.").font(.callout).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if let validation = draft.validation(now: .now, timeZone: timeZone) { Text(validation).foregroundStyle(Theme.amber) }
                    CurveFeedback()
                    Button("Start run once", systemImage: "play.fill") { Task { if await model.start(draft, timeZone: timeZone) { dismiss() } } }
                        .buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(model.saving || draft.validation(now: .now, timeZone: timeZone) != nil)
                    DisclosureGroup("Set points") {
                        ForEach(draft.points) { point in
                            Text("\(point.id == draft.points.first?.id ? "Immediately" : DisplayTime.clock(point.time)) · \(TemperatureDisplay.degrees.text(Int(point.temperature.rounded()), unit: settings.temperatureFormat.degreeUnit, includeUnit: true))")
                                .font(.mono(14, relativeTo: .subheadline)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: 720).padding(16).frame(maxWidth: .infinity)
            }.background(Theme.background).environment(\.timeZone, timeZone).navigationTitle("Run once").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
        }
    }
}
