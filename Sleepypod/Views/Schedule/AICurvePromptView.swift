import SwiftUI

/// Horizontal paged AI curve builder.
/// 4 steps: Describe -> Review -> Import -> Apply.
struct AICurvePromptView: View {
    @Environment(ScheduleManager.self) private var scheduleManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var startPage: Int = 0

    @State private var generator = CurveGenerator()
    @State private var prompt = ""
    @State private var generatedPrompt = ""
    @State private var pastedJSON = ""
    @State private var parsedResult: CurveGenerator.GeneratedCurve?
    @State private var editablePoints: [SetPoint] = []
    @State private var isApplied = false
    @State private var isRunOnce = false
    @State private var copiedPrompt = false
    @State private var copiedJSON = false
    @State private var showSaveDialog = false
    @State private var templateName = ""
    @State private var savedTemplates: [CurveTemplate] = []
    @State private var currentPage: Int = 0
    @State private var didInitialSetup = false
    @State private var parseError: String?
    @State private var showManualField = false
    @State private var libraryDraft: CurveDraft?
    @State private var runOnceReview: RunOnceDraft?
    @FocusState private var isFocused: Bool
    @FocusState private var isJSONFocused: Bool

    private let stepCount = 4

    private let suggestions = [
        "I run hot, bed at 11pm, wake 6:30. Really cold first few hours.",
        "Light sleeper, cold feet. Warm start, gentle cooling, warm wake at 7am.",
        "Post-workout recovery. Bed 10pm, wake 6am. Extra cold for muscles.",
        "I'm always cold. Minimal cooling, cozy all night. Bed 11:30, wake 7:30."
    ]

    private let stepLabels = ["Describe", "Review", "Import", "Apply"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Step indicator
                stepIndicator
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Paged content
                TabView(selection: $currentPage) {
                    describePage.tag(0)
                    promptPage.tag(1)
                    pastePage.tag(2)
                    previewPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: currentPage) { oldValue, newValue in
                    guard didInitialSetup else { return }
                    // Prevent forward swiping past the highest unlocked step
                    let maxAllowed = highestUnlockedPage
                    if newValue > maxAllowed {
                        currentPage = oldValue
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Design Your Curve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                savedTemplates = CurveTemplate.loadAll()
                if startPage > 0 {
                    generatedPrompt = " " // unlock navigation
                    currentPage = startPage
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    didInitialSetup = true
                }
            }
            .alert("Save Template", isPresented: $showSaveDialog) {
                TextField("Template name", text: $templateName)
                Button("Save") { saveAsTemplate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Give this curve a name so you can reuse it later.")
            }
            .sheet(item: $libraryDraft) { NativeCurveEditor(initial: $0) }
            .sheet(item: $runOnceReview) { RunOnceReview(initial: $0) }
        }
    }

    /// The highest page the user is allowed to reach based on completed steps.
    private var highestUnlockedPage: Int {
        if parsedResult != nil { return 3 }
        if !generatedPrompt.isEmpty { return 2 }
        return 0
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(0..<stepCount, id: \.self) { index in
                let isActive = index == currentPage
                let isCompleted = index < currentPage
                let isTappable = index <= highestUnlockedPage && index < currentPage

                Button {
                    if isTappable {
                        Haptics.light()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentPage = index
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(isActive ? Theme.accent : isCompleted ? Theme.accent.opacity(0.4) : Theme.textMuted.opacity(0.3))
                                .frame(width: 20, height: 20)
                            if isCompleted {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.text1)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(isActive ? Theme.text1 : Theme.textMuted)
                            }
                        }
                        Text(stepLabels[index])
                            .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                            .foregroundColor(isActive ? Theme.accent : isCompleted ? Theme.textSecondary : Theme.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!isTappable)

                if index < stepCount - 1 {
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Theme.textMuted.opacity(0.4))
                    Spacer(minLength: 2)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Page 1: Describe

    private var describePage: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Describe your sleep preferences")
                        .font(.headline)
                        .foregroundColor(Theme.text1)

                    TextField("e.g., I run hot, bed at 11pm...", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .focused($isFocused)

                    // Example suggestion cards
                    Text("or try an example:")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)

                    VStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                Haptics.light()
                                prompt = suggestion
                            } label: {
                                Text(suggestion)
                                    .font(.caption)
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(Theme.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Theme.cardBorder, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer(minLength: 120)
                }
                .padding(16)
            }

            floatingBar {
                floatingButton(title: "Next", icon: "arrow.right") {
                    Haptics.medium()
                    isFocused = false
                    generatedPrompt = generator.generatePrompt(preferences: prompt)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentPage = 1
                    }
                }
                .opacity(prompt.isEmpty ? 0.4 : 1.0)
                .disabled(prompt.isEmpty)
            }
        }
    }

    // MARK: - Page 2: Prompt

    private var promptPage: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review & Copy")
                        .font(.headline)
                        .foregroundColor(Theme.text1)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.caption2)
                            Text("Tap **Share** to send directly to ChatGPT, Claude, or Gemini.")
                                .font(.caption2)
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.caption2)
                            Text("Or **Copy** and paste into any AI tool.")
                                .font(.caption2)
                        }
                    }
                    .foregroundColor(Theme.textMuted)

                    Text(generatedPrompt)
                        .font(.mono(11))
                        .foregroundColor(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 120)
                }
                .padding(16)
            }

            floatingBar {
                // Copy
                floatingButton(title: copiedPrompt ? "Copied!" : "Copy", icon: copiedPrompt ? "checkmark" : "doc.on.clipboard") {
                    UIPasteboard.general.string = generatedPrompt
                    withAnimation { copiedPrompt = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copiedPrompt = false } }
                }

                Divider().frame(height: 20).background(Theme.text1.opacity(0.2))

                // Share (manual UIActivityViewController to avoid ShareLink freeze)
                floatingButton(title: "Share", icon: "square.and.arrow.up") {
                    let av = UIActivityViewController(activityItems: [generatedPrompt], applicationActivities: nil)
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let root = windowScene.windows.first?.rootViewController {
                        // Find the topmost presented controller
                        var topVC = root
                        while let presented = topVC.presentedViewController { topVC = presented }
                        av.popoverPresentationController?.sourceView = topVC.view
                        av.popoverPresentationController?.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.maxY - 100, width: 0, height: 0)
                        topVC.present(av, animated: true)
                    }
                }

                Divider().frame(height: 20).background(Theme.text1.opacity(0.2))

                // Next
                floatingButton(title: "Next", icon: "arrow.right") {
                    copiedPrompt = true
                    withAnimation(.easeInOut(duration: 0.25)) { currentPage = 2 }
                }
            }
        }
    }

    // MARK: - Page 3: Paste

    private var pastePage: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Import Results")
                        .font(.headline)
                        .foregroundColor(Theme.text1)

                    Text("Copy the AI response to your clipboard, then tap Paste below.")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)

                    // Manual field (always visible as fallback)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Or paste manually")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)

                        TextField("Paste JSON here...", text: $pastedJSON, axis: .vertical)
                            .lineLimit(5...12)
                            .textFieldStyle(.plain)
                            .font(.mono(11))
                            .padding(12)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Theme.cardBorder, lineWidth: 1)
                            )
                            .accessibilityIdentifier("curve.import.json")
                            .focused($isJSONFocused)
                            .onChange(of: pastedJSON) { _, newValue in
                                parseError = nil
                                // Auto-parse if it looks like JSON
                                if newValue.contains("{") && newValue.contains("}") {
                                    // Debounce
                                    Task {
                                        try? await Task.sleep(for: .milliseconds(500))
                                        if pastedJSON == newValue { // still same text
                                            attemptParse()
                                        }
                                    }
                                }
                            }

                        if !pastedJSON.isEmpty {
                            Button {
                                Haptics.medium()
                                isJSONFocused = false
                                attemptParse()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.right.circle.fill")
                                    Text("Parse & Continue")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundColor(Theme.accent)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Theme.accent.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Error display
                    if let parseError {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                            Text(parseError)
                                .font(.caption)
                        }
                        .foregroundColor(Theme.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Theme.amber.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Spacer(minLength: 120)
                }
                .padding(16)
            }

            floatingBar {
                floatingButton(title: "Paste from Clipboard", icon: "doc.on.clipboard.fill") {
                    if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                        pastedJSON = clipboard
                        attemptParse()
                    }
                }
            }
        }
    }

    // MARK: - Page 4: Preview & Apply

    private var previewPage: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if parsedResult != nil {
                        // Bedtime / wake badge
                        if let result = parsedResult {
                            HStack {
                                Text("Preview & Edit")
                                    .font(.headline)
                                    .foregroundColor(Theme.text1)
                                Spacer()
                                Text("\(result.bedtime) \u{2192} \(result.wake)")
                                    .font(.mono(11))
                                    .foregroundColor(Theme.textMuted)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Theme.cardElevated)
                                    .clipShape(Capsule())
                            }
                        }

                        // AI reasoning
                        if let result = parsedResult, !result.reasoning.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "brain.head.profile")
                                    .font(.caption)
                                    .foregroundColor(Theme.accent)
                                    .padding(.top, 1)
                                Text(result.reasoning)
                                    .font(.caption)
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .padding(10)
                            .background(Theme.accent.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        // Temperature curve chart
                        curveChart
                        Text("Set points show scheduled temperatures, not predicted sleep stages.")
                            .font(.caption).foregroundStyle(Theme.text2)

                        if typeSize.isAccessibilitySize { previewActions }

                        // Editable set points
                        CurveSetPointList(
                            points: $editablePoints,
                            temperatureFormat: settingsManager.temperatureFormat,
                            onChanged: { syncResultFromEdits() }
                        )

                        // Error display
                        if let error = generator.error {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                Text(error)
                                    .font(.caption)
                            }
                            .foregroundColor(Theme.amber)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // Placeholder when no result yet
                        VStack(spacing: 12) {
                            Image(systemName: "chart.xyaxis.line")
                                .font(.largeTitle)
                                .foregroundColor(Theme.textMuted)
                            Text("Complete the previous steps to preview your curve.")
                                .font(.subheadline)
                                .foregroundColor(Theme.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 80)
                    }

                    Spacer(minLength: 120)
                }
                .padding(16)
            }.accessibilityIdentifier("curve.import.preview.scroll")

            if !typeSize.isAccessibilitySize { floatingBar { previewActionButtons } }
        }
    }

    private var previewActions: some View {
        VStack(alignment: .leading, spacing: 18) { previewActionButtons }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
    @ViewBuilder private var previewActionButtons: some View {
        floatingButton(title: "Save", icon: "bookmark") {
            templateName = parsedResult?.profileName ?? ""
            showSaveDialog = true
        }
        if !typeSize.isAccessibilitySize { Divider().frame(height: 20).background(Theme.text1.opacity(0.2)) }
        floatingButton(title: isApplied ? "Applied!" : APIBackend.current == .freeSleep ? "Apply" : "Review", icon: isApplied ? "checkmark" : "calendar.badge.plus") {
            applyToSchedule()
        }.accessibilityIdentifier("curve.import.review")
        if APIBackend.current != .freeSleep {
            if !typeSize.isAccessibilitySize { Divider().frame(height: 20).background(Theme.text1.opacity(0.2)) }
            floatingButton(title: isRunOnce ? "Started!" : "Use Now", icon: isRunOnce ? "checkmark" : "play.fill") { useNow() }
        }
    }

    // MARK: - Saved Templates

    private var templateChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundColor(Theme.accent)
                Text("SAVED TEMPLATES")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.textSecondary)
                    .tracking(1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(savedTemplates) { template in
                        Button {
                            Haptics.light()
                            loadTemplate(template)
                        } label: {
                            HStack(spacing: 6) {
                                Text(template.name)
                                    .font(.caption2.weight(.medium))
                                    .foregroundColor(Theme.text1)
                                    .lineLimit(1)

                                Button {
                                    Haptics.light()
                                    deleteTemplate(template)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(Theme.textMuted)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.cardElevated)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Curve Chart

    private var orderedPreview: [CurvePoint] {
        CurvePoint.ordered(editablePoints.map { CurvePoint(id: $0.id, time: $0.time, temperature: Double($0.tempF)) })
    }
    private var curveChart: some View {
        TemperatureCurve(points: orderedPreview.map { RunOnceSetPoint(time: $0.time, temperature: $0.temperature) },
                         bedtime: orderedPreview.first?.time ?? "22:00", wake: orderedPreview.last?.time ?? "07:00")
            .padding(.vertical, 12)
            .accessibilityIdentifier("curve.import.graph")
            .accessibilityValue(orderedPreview.map { "\($0.time) · \(Int($0.temperature))°F" }.joined(separator: ", "))
    }

    // MARK: - Floating Bar

    private func floatingBar(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)

        }
        .padding(.bottom, 20)
    }

    private func floatingButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Theme.text1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func attemptParse() {
        parseError = nil
        isJSONFocused = false

        if let result = generator.parse(json: pastedJSON) {
            applyParsedResult(result)
            // Auto-advance to page 4
            withAnimation(.easeInOut(duration: 0.25)) {
                currentPage = 3
            }
        } else {
            parseError = generator.error ?? "Could not parse JSON. Make sure you pasted the complete AI response."
        }
    }

    /// The labels describe scheduled temperature changes, never inferred sleep stages.
    private func applyParsedResult(_ result: CurveGenerator.GeneratedCurve) {
        parsedResult = result
        let ordered = CurvePoint.ordered(result.points.map { CurvePoint(time: $0.key, temperature: Double($0.value)) })
        editablePoints = ordered.enumerated().map { index, point in
            SetPoint(time: point.time, tempF: Int(point.temperature), phase: pointLabel(at: index, in: ordered))
        }
        generator.error = nil
    }

    private func pointLabel(at index: Int, in points: [CurvePoint]) -> String {
        guard index > 0 else { return "Start" }
        if points[index].temperature < points[index - 1].temperature { return "Cooling" }
        if points[index].temperature > points[index - 1].temperature { return "Warming" }
        return "Hold"
    }

    private func syncResultFromEdits() {
        guard let old = parsedResult else { return }
        let ordered = orderedPreview
        for (index, point) in ordered.enumerated() {
            guard let local = editablePoints.firstIndex(where: { $0.id == point.id }) else { continue }
            editablePoints[local].phase = pointLabel(at: index, in: ordered)
        }
        var newPoints: [String: Int] = [:]
        for p in editablePoints {
            newPoints[p.time] = p.tempF
        }
        parsedResult = CurveGenerator.GeneratedCurve(
            bedtime: old.bedtime,
            wake: old.wake,
            points: newPoints,
            reasoning: old.reasoning,
            profileName: old.profileName, nowCurve: old.nowCurve
        )
        generator.lastResult = parsedResult
        isApplied = false
    }

    // MARK: - Template Actions

    private func loadTemplate(_ template: CurveTemplate) {
        let result = CurveGenerator.GeneratedCurve(
            bedtime: template.bedtime,
            wake: template.wake,
            points: template.points,
            reasoning: template.reasoning,
            profileName: template.name, nowCurve: nil
        )
        generator.lastResult = result
        applyParsedResult(result)
        withAnimation(.easeInOut(duration: 0.25)) {
            currentPage = 3
        }
    }

    private func deleteTemplate(_ template: CurveTemplate) {
        CurveTemplate.delete(named: template.name)
        savedTemplates = CurveTemplate.loadAll()
    }

    private func saveAsTemplate() {
        guard let result = parsedResult, !templateName.isEmpty else { return }
        if APIBackend.current != .freeSleep {
            var draft = sharedDraft(result)
            draft.name = String(templateName.prefix(30)); draft.days = CurveDays(); draft.active = false
            libraryDraft = draft
            return
        }
        var points: [String: Int] = [:]
        for p in editablePoints {
            points[p.time] = p.tempF
        }
        let template = CurveTemplate(
            name: templateName,
            points: points,
            bedtime: result.bedtime,
            wake: result.wake,
            reasoning: result.reasoning
        )
        CurveTemplate.add(template)
        savedTemplates = CurveTemplate.loadAll()
        Haptics.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            dismiss()
        }
    }

    // MARK: - Apply to Schedule

    private func applyToSchedule() {
        guard let result = parsedResult else { return }
        var finalPoints: [String: Int] = [:]
        for p in editablePoints {
            finalPoints[p.time] = p.tempF
        }
        let finalResult = CurveGenerator.GeneratedCurve(
            bedtime: result.bedtime,
            wake: result.wake,
            points: finalPoints,
            reasoning: result.reasoning,
            profileName: result.profileName, nowCurve: result.nowCurve
        )
        applyResult(finalResult)
    }

    private func applyResult(_ result: CurveGenerator.GeneratedCurve) {
        if APIBackend.current != .freeSleep {
            libraryDraft = sharedDraft(result)
            return
        }
        Task {
            guard var schedules = scheduleManager.schedules else { return }
            let side = scheduleManager.selectedSide.primarySide

            for day in scheduleManager.selectedDays {
                var sideSchedule = schedules.schedule(for: side)
                var daily = sideSchedule[day]
                if daily.temperatures.isEmpty && daily.power.endAction == nil && settingsManager.supportsScheduleEndAction {
                    daily.power.endAction = settingsManager.settings?.defaultScheduleEndAction
                }
                daily.temperatures = result.points
                daily.power.on = result.bedtime
                daily.power.off = result.wake
                daily.power.enabled = true
                daily.alarm.time = result.wake
                daily.alarm.enabled = true
                sideSchedule[day] = daily
                schedules.setSchedule(sideSchedule, for: side)

                if scheduleManager.selectedSide == .both {
                    var other = schedules.schedule(for: side == .left ? .right : .left)
                    other[day] = daily
                    schedules.setSchedule(other, for: side == .left ? .right : .left)
                }
            }

            scheduleManager.schedules = schedules
            do {
                let api = APIBackend.current.createClient()
                scheduleManager.schedules = try await api.updateSchedules(schedules, days: scheduleManager.selectedDays)
                withAnimation { isApplied = true }
                Haptics.success()
            } catch {
                Log.general.error("Failed to apply AI curve: \(error)")
            }
        }
    }

    private func useNow() {
        guard let result = parsedResult else { return }
        let side = scheduleManager.selectedSide.primarySide
        if APIBackend.current != .freeSleep {
            let draft = sharedDraft(result)
            let payload = draft.payload
            let curve = PodCurve(id: 0, name: payload.name, bedtime: payload.bedtime, wake: payload.wake, points: payload.points, notes: payload.notes)
            var review = RunOnceDraft(curve: curve, side: side, timeZone: TimeZone(identifier: settingsManager.timeZone) ?? .current)
            review.setWake(result.wake)
            runOnceReview = review
            return
        }

        let setPoints: [RunOnceSetPoint]

        if let nowCurve = result.nowCurve, !nowCurve.isEmpty {
            // Use the AI-generated "start now" curve (properly shaped for shorter duration)
            setPoints = nowCurve.map { time, temp in
                RunOnceSetPoint(time: time, temperature: Double(temp))
            }
        } else {
            // Fallback: proportionally shift the original curve times
            let now = Date()
            let cal = Calendar.current
            let nowMins = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
            let roundedNow = (nowMins / 5) * 5
            let bedMins = hhmm(result.bedtime)
            let wakeMins = hhmm(result.wake)
            let originalSpan = (wakeMins - bedMins + 1440) % 1440
            let newSpan = (wakeMins - roundedNow + 1440) % 1440

            setPoints = editablePoints.map { p in
                let ptMins = hhmm(p.time)
                let origOffset = (ptMins - bedMins + 1440) % 1440
                let newOffset = originalSpan > 0 ? origOffset * newSpan / originalSpan : origOffset
                let newMins = (roundedNow + newOffset) % 1440
                let newTime = String(format: "%02d:%02d", newMins / 60, newMins % 60)
                return RunOnceSetPoint(time: newTime, temperature: Double(p.tempF))
            }
        }

        Task {
            do {
                let api = APIBackend.current.createClient()
                _ = try await api.startRunOnce(
                    side: side,
                    setPoints: setPoints,
                    wakeTime: result.wake
                )

                if scheduleManager.selectedSide == .both {
                    let other: Side = side == .left ? .right : .left
                    _ = try await api.startRunOnce(
                        side: other,
                        setPoints: setPoints,
                        wakeTime: result.wake
                    )
                }

                withAnimation { isRunOnce = true }
                Haptics.success()
                try? await Task.sleep(for: .seconds(1))
                NotificationCenter.default.post(
                    name: .switchToTempTab,
                    object: scheduleManager.selectedSide
                )
            } catch {
                Log.general.error("Failed to start run-once from AI curve: \(error)")
            }
        }
    }

    private func hhmm(_ time: String) -> Int {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return 0 }
        return h * 60 + m
    }

    /// AI output stays a reviewable draft; schedule ownership is applied only by the library editor.
    private func sharedDraft(_ result: CurveGenerator.GeneratedCurve) -> CurveDraft {
        var draft = CurveDraft()
        draft.name = String((result.profileName.isEmpty ? "Personal curve" : result.profileName).prefix(30))
        draft.points = editablePoints.map { CurvePoint(time: $0.time, temperature: Double($0.tempF)) }
        draft.notes = String(result.reasoning.prefix(1000))
        draft.bedtime = draft.ordered.first?.time ?? result.bedtime
        draft.wake = draft.ordered.last?.time ?? result.wake
        draft.coolest = Int(draft.points.map(\.temperature).min() ?? 68)
        draft.warmest = Int(draft.points.map(\.temperature).max() ?? 86)
        for side in scheduleManager.selectedSide.sides { draft.days[side] = DayOfWeek.weekdays.filter { scheduleManager.selectedDays.contains($0) } }
        return draft
    }
}
