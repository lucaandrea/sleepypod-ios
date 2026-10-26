import SwiftUI

// MARK: - Data Model

struct SetPoint: Identifiable, Equatable {
    let id: UUID
    var time: String    // "HH:mm" 24-hour format
    var tempF: Int      // 55-110
    var phase: String   // "Warm-up", "Cool-down", "Deep Sleep", "Maintain", "Pre-Wake", "Wake"

    init(id: UUID = UUID(), time: String, tempF: Int, phase: String) {
        self.id = id
        self.time = time
        self.tempF = tempF
        self.phase = phase
    }
}

// MARK: - SetPointEditor

struct CurveSetPointList: View {
    @Binding var points: [SetPoint]
    var temperatureFormat: TemperatureFormat
    var onChanged: (() -> Void)?

    @State private var expandedTimeID: UUID?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("Set Points")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.text1)
                Spacer()
                Button {
                    Haptics.light()
                    addPoint()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Add")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Rows
            let sorted = orderedPoints
            ForEach(sorted) { point in
                VStack(spacing: 0) {
                    setPointRow(point: point)

                    // Inline time picker when expanded
                    if expandedTimeID == point.id {
                        timePicker(for: point)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .onDelete { offsets in
                guard points.count > 3 else { return }
                var sorted = orderedPoints
                sorted.remove(atOffsets: offsets)
                points = sorted
                onChanged?()
            }
        }
    }

    // MARK: - Row

    private func setPointRow(point: SetPoint) -> some View {
        HStack(spacing: 10) {
            // Phase dot
            Circle()
                .fill(phaseColor(point.phase))
                .frame(width: 8, height: 8)

            // Phase label
            Text(point.phase)
                .font(.system(size: 9))
                .foregroundColor(Theme.textMuted)
                .frame(width: 60, alignment: .leading)
                .lineLimit(1)

            // Tappable time
            Button {
                Haptics.light()
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedTimeID = expandedTimeID == point.id ? nil : point.id
                }
            } label: {
                Text(point.time)
                    .font(.mono(13, weight: .medium))
                    .foregroundColor(Theme.text1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        expandedTimeID == point.id
                            ? Theme.accent.opacity(0.15)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer()

            // Temperature stepper
            HStack(spacing: 8) {
                Button {
                    Haptics.light()
                    updateTemp(id: point.id, delta: -1)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.cardElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Text(TemperatureConversion.displayTemp(point.tempF, format: temperatureFormat))
                    .font(.mono(13, weight: .semibold))
                    .foregroundColor(TempColor.forOffset(point.tempF - 80))
                    .frame(minWidth: 48)

                Button {
                    Haptics.light()
                    updateTemp(id: point.id, delta: 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.cardElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Delete button
            if points.count > 3 {
                Button {
                    Haptics.light()
                    deletePoint(id: point.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.error.opacity(0.7))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Inline Time Picker

    private func timePicker(for point: SetPoint) -> some View {
        let binding = Binding<Date>(
            get: {
                dateFromTimeString(point.time) ?? Date()
            },
            set: { newDate in
                updateTime(id: point.id, date: newDate)
            }
        )

        return DatePicker(
            "",
            selection: binding,
            displayedComponents: .hourAndMinute
        )
        .datePickerStyle(.wheel)
        .environment(\.timeZone, .gmt)
        .labelsHidden()
        .frame(height: 120)
        .clipped()
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func updateTemp(id: UUID, delta: Int) {
        if let index = points.firstIndex(where: { $0.id == id }) {
            let newTemp = max(55, min(110, points[index].tempF + delta))
            points[index].tempF = newTemp
            onChanged?()
        }
    }

    private func updateTime(id: UUID, date: Date) {
        if let index = points.firstIndex(where: { $0.id == id }) {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .gmt; formatter.dateFormat = "HH:mm"
            points[index].time = formatter.string(from: date)
            // Auto-sort after time change
            points = orderedPoints
            onChanged?()
        }
    }

    private func deletePoint(id: UUID) {
        guard points.count > 3 else { return }
        points.removeAll { $0.id == id }
        onChanged?()
    }

    private func addPoint() {
        let sorted = orderedPoints
        let midIndex = sorted.count / 2
        let refTime = sorted.indices.contains(midIndex) ? sorted[midIndex].time : "02:00"
        let refTemp = sorted.indices.contains(midIndex) ? sorted[midIndex].tempF : 74

        let newTime = nudgeTime(refTime, by: 15)
        let newPoint = SetPoint(time: newTime, tempF: refTemp, phase: "Maintain")
        points.append(newPoint)
        points = orderedPoints
        onChanged?()
    }

    // MARK: - Helpers

    private func nudgeTime(_ time: String, by minutes: Int) -> String {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return time }
        let totalMinutes = (parts[0] * 60 + parts[1] + minutes) % (24 * 60)
        return String(format: "%02d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    private func dateFromTimeString(_ time: String) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        // A recurring clock is not today's date; UTC avoids losing times in a DST gap.
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: parts[0], minute: parts[1]))
    }

    /// Use the same overnight gap rule as the saved-curve payload and chart.
    private var orderedPoints: [SetPoint] {
        let converted = points.map { CurvePoint(id: $0.id, time: $0.time, temperature: Double($0.tempF)) }
        let byID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        return CurvePoint.ordered(converted).compactMap { byID[$0.id] }
    }

    private func phaseColor(_ phase: String) -> Color {
        let lower = phase.lowercased()
        if lower.contains("warm") { return Theme.warming }
        if lower.contains("cool") { return Theme.cooling }
        if lower.contains("deep") { return Color(hex: "2563eb") }
        if lower.contains("maintain") { return Theme.textSecondary }
        if lower.contains("pre") && lower.contains("wake") { return Theme.amber }
        if lower.contains("wake") { return Theme.textMuted }
        return Theme.textSecondary
    }
}

struct SetPointEditor: View {
    let phase: SchedulePhase
    @Environment(ScheduleManager.self) private var schedule
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()
    @State private var temperature = 80
    @State private var saving = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden().frame(maxHeight: 180)
                GlassEffectContainer(spacing: 24) {
                    HStack(spacing: 24) {
                        stepButton("minus", delta: -1)
                        Text(TemperatureConversion.displayTemp(temperature, format: settings.temperatureFormat))
                            .font(.mono(34, weight: .light, relativeTo: .largeTitle))
                            .foregroundStyle(TempColor.forScheduled(temperature))
                            .contentTransition(.numericText(value: Double(temperature)))
                            .frame(minWidth: 110)
                            .accessibilityLabel("Temperature")
                            .accessibilityValue(TemperatureConversion.displayTemp(temperature, format: settings.temperatureFormat))
                            .accessibilityAdjustableAction { direction in
                                temperature = min(110, max(55, temperature + (direction == .increment ? 1 : -1)))
                            }
                        stepButton("plus", delta: 1)
                    }
                }
                if let error = schedule.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle(phase.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        saving = true
                        Task {
                            let f = DateFormatter(); f.dateFormat = "HH:mm"
                            if await schedule.editPhase(oldTime: phase.time, newTime: f.string(from: time), temperature: temperature) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving)
                }
            }
            .onAppear {
                temperature = phase.temperatureF
                time = Calendar.current.date(bySettingHour: DisplayTime.minutes(phase.time) / 60, minute: DisplayTime.minutes(phase.time) % 60, second: 0, of: Date()) ?? Date()
            }
        }
    }

    private func stepButton(_ symbol: String, delta: Int) -> some View {
        Button {
            Haptics.light()
            withAnimation(.snappy(duration: 0.2)) { temperature = min(110, max(55, temperature + delta)) }
        } label: {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Theme.text1)
                .frame(width: 52, height: 52).chromeSurface(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta < 0 ? "Cooler" : "Warmer")
    }
}
