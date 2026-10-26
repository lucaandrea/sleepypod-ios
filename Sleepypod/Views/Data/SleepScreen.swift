import FreeSleepKit
import SwiftUI

struct SleepScreen: View {
    enum Period: String {
        case night = "Night"
        case week = "Week"
        case month = "Month"
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(MetricsManager.self) private var metrics
    @Environment(SettingsManager.self) private var settings
    @Environment(UserProfile.self) private var profile
    @Environment(HealthSyncService.self) private var health
    @Environment(NativeActionSession.self) private var nativeActions
    @Environment(StageModelStore.self) private var stageModels
    @State private var selectedDate = SleepCalendar.previousNight(
        calendar: SleepCalendar.calendar(
            timeZone: UserDefaults.standard.string(forKey: "podTimeZone") ?? "America/Los_Angeles"))
    @State private var period: Period =
        ["week", "weektrend"].contains(DebugRoute.current) ? .week : DebugRoute.current == "month" ? .month : .night
    @State private var analyzer = SleepAnalyzer()
    @State private var agreement: Double?
    @State private var nightlyAgreement: [Date: Double] = [:]
    @State private var showWatch = false
    @State private var showStages = false
    @State private var showStageRules = false
    @State private var monthRecords: [SleepRecord] = []
    @State private var monthError: String?
    @State private var monthLoading = false
    @State private var editingRecord: SleepRecord?
    @State private var showRaw = false
    @State private var showOptions = false
    @State private var initialized = false
    @State private var refreshRevision = 0
    @State private var podStages = PodStageNightWorkspace()
    @State private var periodStages = SleepPeriodStageWorkspace()
    @State private var localWeekStages: [Int: SleepNightStageSummary] = [:]
    @State private var periodStageRevision = 0
    @State private var weekSummaries: [SleepNightSummary] = []
    @State private var weekSummarySide: Side?
    @State private var weekSummaryStart: Date?
    @AppStorage("nightStageSource") private var nightStageSource = "pod"
    private var usesPodStages: Bool { APIBackend.current != .freeSleep && nightStageSource == "pod" }
    private var displayedEpochs: [SleepAnalyzer.SleepEpoch] { usesPodStages ? podStages.epochs : analyzer.stages }
    private var displayedStageSource: String { usesPodStages ? podStages.result?.sourceLabel ?? "Pod" : "This iPhone" }

    private var calendar: Calendar { SleepCalendar.calendar(timeZone: settings.timeZone) }
    // A day can hold several records (naps, getting up and back in); the longest sleep is the night.
    private var record: SleepRecord? {
        metrics.sleepRecords.filter {
            $0.side == metrics.selectedSide.rawValue
                && calendar.isDate(
                    SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar), inSameDayAs: selectedDate)
        }
        .max { $0.sleepPeriodSeconds < $1.sleepPeriodSeconds }
    }
    private var vitals: [VitalsRecord] {
        guard let record else { return [] }
        return metrics.vitalsRecords.filter {
            $0.side == record.side && $0.date >= record.enteredBedDate && $0.date < record.leftBedDate
        }
    }
    private var weekDays: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: metrics.selectedWeekStart) }
    }
    private var weekNights: [SleepNightSummary] {
        if weekSummarySide == metrics.selectedSide, weekSummaryStart == metrics.selectedWeekStart {
            return weekSummaries
        }
        return SleepPeriodSummary.nights(
            days: weekDays, records: [], vitals: [], side: metrics.selectedSide, calendar: calendar)
    }
    private var weekStages: [Int: SleepNightStageSummary] { usesPodStages ? periodStages.summaries : localWeekStages }
    private var periodStageKey: String {
        "\(period.rawValue)-\(metrics.selectedSide.rawValue)-\(metrics.selectedWeekStart)-\(usesPodStages)-\(periodStageRevision)-"
            + weekNights.compactMap(\.main).map { "\($0.id):\($0.sleepPeriodSeconds)" }.joined(separator: ",")
    }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate }
    private var monthDays: [Date] {
        let count = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: monthStart) }
    }
    private var sideName: String { settings.sideName(for: metrics.selectedSide) }
    private var isDemo: Bool { APIBackend.current.isDemo }
    /// The Watch is only comparable on the side this iPhone's wearer sleeps on.
    private var canCompareWatch: Bool {
        isDemo
            || (health.enabled && (health.preferences.readSleep || health.preferences.readVitals)
                && metrics.selectedSide == profile.defaultSide)
    }
    private var canMoveForward: Bool {
        let today = calendar.startOfDay(for: Date())
        switch period {
        case .night: return selectedDate < today
        case .week: return (calendar.date(byAdding: .day, value: 7, to: metrics.selectedWeekStart) ?? today) <= today
        case .month: return (calendar.date(byAdding: .month, value: 1, to: monthStart) ?? today) <= today
        }
    }

    var body: some View {
        NavigationStack {
            lifecycleContent
                .sheet(item: $editingRecord) { record in SleepRecordEditor(record: record) { await reload() } }
                .sheet(isPresented: $showRaw) {
                    SleepRangeExportSheet(side: metrics.selectedSide, window: exportWindow)
                }
                .navigationDestination(isPresented: $showWatch) {
                    if let record {
                        WatchComparisonView(
                            record: record, epochs: displayedEpochs, vitals: filteredVitals,
                            stageSourceLabel: displayedStageSource, stageGapTolerance: usesPodStages ? 0 : 300)
                    }
                }
                .navigationDestination(isPresented: $showStages) {
                    if let record { StageComparisonView(record: record, side: metrics.selectedSide) }
                }
                .navigationDestination(isPresented: $showStageRules) {
                    RemoteStageRulesScreen(side: metrics.selectedSide)
                }
                .navigationDestination(isPresented: $showOptions) {
                    List { standardSleepOptions; Section("Personal tools") { personalOptions } }
                        .navigationTitle("Sleep options")
                        .navigationBarTitleDisplayMode(.inline)
                        .accessibilityIdentifier("sleep.optionsList")
                }
        }
    }
    private var lifecycleContent: some View {
        scrollContent
            .environment(\.timeZone, calendar.timeZone)
            .task {
                guard !initialized else { return }
                initialized = true
                metrics.timeZone = settings.timeZone
                if let request = metrics.sleepNavigation { openSleep(request) }
                else {
                    metrics.selectedSide = profile.defaultSide
                    selectedDate = SleepCalendar.previousNight(calendar: calendar)
                }
                await refresh()
            }
            .onChange(of: metrics.sleepNavigation?.id) {
                if let request = metrics.sleepNavigation { openSleep(request) }
            }
            .task(id: selectedDate) { if initialized { await refresh() } }
            .onChange(of: settings.timeZone) {
                metrics.timeZone = settings.timeZone
                Task { await reload() }
            }
            .task(id: "\(period.rawValue)-\(monthStart.timeIntervalSince1970)-\(metrics.selectedSide.rawValue)") {
                if period == .month { await fetchMonth() }
            }
            .onChange(of: metrics.selectedSide) { Task { await refresh() } }
            .onChange(of: stageModels.activeVersion) { Task { await refresh() } }
            .task(
                id:
                    "\(metrics.selectedSide.rawValue)-\(record?.id ?? -1)-\(selectedDate)-\(refreshRevision)-\(nightStageSource)"
            ) {
                guard usesPodStages else { return }
                let client = APIBackend.current.createClient()
                await podStages.load(recordID: record?.id, side: metrics.selectedSide, fetch: client.getSleepStages)
            }
            .task(id: periodStageKey) {
                guard period == .week, usesPodStages else { return }
                await periodStages.load(
                    records: weekNights.compactMap(\.main), side: metrics.selectedSide,
                    fetch: APIBackend.current.createClient().getSleepStages)
            }
            .refreshable { await reload() }
    }

    private func openSleep(_ request: SleepNavigationRequest) {
        if let side = Side(rawValue: request.record.side) { metrics.selectedSide = side }
        period = .night
        selectedDate = SleepCalendar.nightDate(for: request.record.enteredBedDate, calendar: calendar)
    }
    private var exportWindow: DateInterval {
        let startDay = period == .night ? selectedDate : period == .week ? metrics.selectedWeekStart : monthStart
        let endDay =
            calendar.date(byAdding: period == .month ? .month : .day, value: period == .week ? 7 : 1, to: startDay)
            ?? startDay
        return SleepCalendar.nightWindow(from: startDay, until: endDay, calendar: calendar)
    }
    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                subtitle.padding(.horizontal, 4)
                SegmentedControl(
                    segments: [
                        .init(value: Period.night, title: "Night"),
                        .init(value: .week, title: "Week"),
                        .init(value: .month, title: "Month")
                    ], selection: $period
                ).padding(.horizontal, 4).padding(.bottom, 8)
                periodContent
                dataFooter
            }.padding(.horizontal, 16).padding(.bottom, 24)
        }.defaultScrollAnchor(DebugRoute.current == "weektrend" ? .bottom : nil)
            .background(Theme.background).navigationTitle("Sleep").settingsToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { sleepOptions.accessibilityLabel("Sleep options") }
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Previous \(period.rawValue.lowercased())", systemImage: "chevron.left") { move(-1) }
                    Button("Next \(period.rawValue.lowercased())", systemImage: "chevron.right") { move(1) }.disabled(
                        !canMoveForward)
                }
            }
    }
    @ViewBuilder private var periodContent: some View {
        switch period {
        case .night: nightContent
        case .week: weekContent
        case .month: monthContent
        }
    }
    @ViewBuilder private var dataFooter: some View {
        if let notice = metrics.notice { Text(notice).font(.footnote).foregroundStyle(Theme.text2) }
        if let error = metrics.error { Text(error).font(.footnote).foregroundStyle(Theme.amber) }
        if period == .month, let monthError { Text(monthError).font(.footnote).foregroundStyle(Theme.amber) }
        NavigationLink {
            BiometricsScreen(side: metrics.selectedSide, date: selectedDate)
        } label: {
            Label("Biometrics", systemImage: "waveform.path.ecg")
        }
        Button("Raw data", systemImage: "square.and.arrow.up") { showRaw = true }.disabled(
            metrics.isLoading || metrics.error != nil
        ).padding(.vertical, 8)
    }
    private func reload() async {
        periodStageRevision += 1
        await refresh()
        if period == .month { await fetchMonth() }
    }

    @ViewBuilder private var sleepOptions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Button { showOptions = true } label: { Image(systemName: "ellipsis") }
        } else {
            Menu { sleepOptionLinks } label: { Image(systemName: "ellipsis") }
        }
    }
    private var sleepOptionLinks: some View {
        Group {
            standardSleepOptions
            Menu("Personal tools", systemImage: "person.crop.circle") { personalOptions }
        }
    }
    private var standardSleepOptions: some View {
        Group {
            NavigationLink("Biometrics") { BiometricsScreen(side: metrics.selectedSide, date: selectedDate) }
                .accessibilityIdentifier("sleep.openBiometrics")
            if APIBackend.current != .freeSleep {
                Button("Pod sleep stages") { showStageRules = true }.accessibilityIdentifier("sleep.openStageRules")
            }
            Button("Raw data", systemImage: "square.and.arrow.up") { showRaw = true }.disabled(
                metrics.isLoading || metrics.error != nil
            ).accessibilityIdentifier("sleep.openRawData")
            if let record, APIBackend.current != .freeSleep {
                Button("Edit sleep times", systemImage: "pencil") {
                    metrics.mutationError = nil
                    editingRecord = record
                }
            }
        }
    }
    private var personalOptions: some View {
        Group {
            NavigationLink("Morning check-in") { MorningJournalDestination(side: metrics.selectedSide) }
            NavigationLink("Personal reports") { PodFeatureScreen(.reports, side: metrics.selectedSide.rawValue, nativeActions: nativeActions.bridge) }
            NavigationLink("Sleep coach") { PodFeatureScreen(.coach, side: metrics.selectedSide.rawValue, nativeActions: nativeActions.bridge) }
            if APIBackend.current == .freeSleep {
                NavigationLink("Recorded episodes") { PodFeatureScreen(.history, side: metrics.selectedSide.rawValue) }
            } else {
                NavigationLink("Imported history") { ImportedHistoryScreen(side: metrics.selectedSide) }
            }
        }
    }

    private var subtitle: some View {
        HStack(spacing: 0) {
            Text("\(dateLabel) · ")
            Menu {
                Picker("Side", selection: Binding(get: { metrics.selectedSide }, set: { metrics.selectedSide = $0 })) {
                    ForEach(Side.allCases) { side in Text(settings.sideName(for: side)).tag(side) }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(sideName)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Theme.text2)
            }
            .accessibilityLabel("Side, \(sideName)")
        }
        .font(.mono(12, relativeTo: .caption)).foregroundStyle(Theme.text2)
        .padding(.top, -4)
    }

    private var dateLabel: String {
        switch period {
        case .night:
            return selectedDate.formatted(
                Date.FormatStyle(timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day())
        case .week:
            let end =
                calendar.date(byAdding: .day, value: 6, to: metrics.selectedWeekStart) ?? metrics.selectedWeekStart
            return
                "\(metrics.selectedWeekStart.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.abbreviated).day())) – \(end.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.abbreviated).day()))"
        case .month:
            return monthStart.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.wide).year())
        }
    }

    // MARK: Night

    @ViewBuilder private var nightContent: some View {
        if let record {
            SleepSummaryCardView(
                record: record, score: usesPodStages ? podStages.result?.score : analyzer.qualityScore,
                sleepSeconds: usesPodStages ? podStages.result?.sleepSeconds : nil)
            if APIBackend.current != .freeSleep {
                Button("Edit times", systemImage: "pencil") {
                    metrics.mutationError = nil
                    editingRecord = record
                }
                .font(.subheadline).padding(.horizontal, 4).accessibilityIdentifier("sleep.editTimes")
            }
            if APIBackend.current != .freeSleep {
                Picker("Night stage source", selection: $nightStageSource) {
                    Text("Pod").tag("pod")
                    Text("This iPhone").tag("phone")
                }
                .pickerStyle(.segmented).accessibilityIdentifier("sleep.stageSource")
            }
            if usesPodStages {
                if podStages.loading { ProgressView("Loading Pod stages…") }
                if let error = podStages.error {
                    Text(error).font(.footnote).foregroundStyle(Theme.amber)
                    Button("Retry Pod stages") { Task { await reload() } }
                }
                SleepStagesTimelineView(
                    stages: displayedEpochs, qualityScore: podStages.result?.score, sourceLabel: displayedStageSource,
                    gapTolerance: 0, showDurations: true)
                if let result = podStages.result { PodStageSourceDetails(result: result) }
                if let warning = podStages.result?.stageView?.provenance.warning {
                    Text(warning).font(.footnote).foregroundStyle(Theme.amber)
                }
                Text(
                    "The Pod’s current classifier determines this view. Health sync uses the iPhone’s analysis settings."
                ).font(.caption).foregroundStyle(Theme.text3)
            } else {
                SleepStagesTimelineView(
                    stages: analyzer.stages, qualityScore: analyzer.qualityScore,
                    source: analyzer.source, modelName: stageModels.active?.title, sourceLabel: "This iPhone",
                    showDurations: true)
            }
            vitalsLayout {
                vital("HR", unit: "bpm", key: \.heartRate, decimals: 0, icon: "heart", color: Theme.red)
                vital("HRV", unit: "ms", key: \.hrv, decimals: 0, icon: "waveform.path.ecg", color: Theme.cool)
                vital("BREATH", unit: "br/min", key: \.breathingRate, decimals: 1, icon: "lungs", color: Theme.green)
            }
            Text("Bed exits · \(record.timesExitedBed)").font(.footnote).foregroundStyle(Theme.text2).padding(
                .horizontal, 4)
            if health.hasWriteAuthorization && metrics.selectedSide == profile.defaultSide && !isDemo {
                healthReceipt(record)
            }
            if canCompareWatch {
                watchRow
                stagesRow
            }
            if APIBackend.current != .freeSleep {
                NavigationLink {
                    WatchComparisonView(
                        record: record, epochs: displayedEpochs, vitals: vitals, source: .controller,
                        stageSourceLabel: displayedStageSource, stageGapTolerance: usesPodStages ? 0 : 300)
                } label: {
                    Label("Imported Apple Watch", systemImage: "applewatch")
                }.padding(.vertical, 8).accessibilityIdentifier("sleep.importedWatch")
            }
            barsCard(
                days: weekDays, hours: weekNights.map { Double($0.seconds) / 3600 }, spacing: 10, radius: 6, height: 70
            ) { _, day in
                Text(day, format: Date.FormatStyle(timeZone: calendar.timeZone).weekday(.narrow)).frame(
                    maxWidth: .infinity
                ).foregroundStyle(Theme.text2)
            }
        } else if metrics.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            ContentUnavailableView(
                "No sleep recorded", systemImage: "moon",
                description: Text("Choose another night to see sleep and vitals."))
        }
    }

    private var filteredVitals: [VitalsRecord] {
        // Preserve each source reading; the metric plot handles missing or nonfinite values separately.
        vitals
    }

    private var vitalsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
    }

    private func vital(
        _ title: String, unit: String, key: KeyPath<VitalsRecord, Double?>, decimals: Int,
        icon: String, color: Color
    ) -> some View {
        let records = filteredVitals
        let metric: BiometricMetric = key == \.heartRate ? .heartRate : key == \.hrv ? .hrv : .breathingRate
        let average = BiometricPlot(metric: metric, records: records).stats?.average
        let display = average.map { String(format: "%.\(decimals)f", $0) } ?? "—"
        return NavigationLink {
            BiometricsScreen(side: metrics.selectedSide, date: selectedDate, period: .night)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(title, size: 10)
                Text(display).font(.mono(24, weight: .light, relativeTo: .title2)).foregroundStyle(Theme.text1)
                Text(unit).font(.mono(10, relativeTo: .caption2)).foregroundStyle(Theme.text3)
            }
            .cardStyle(radius: 18, vertical: 14, horizontal: 14)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(display) \(unit)")
        .accessibilityHint("Shows the full chart")
    }

    private func healthReceipt(_ record: SleepRecord) -> some View {
        HStack(spacing: 10) {
            if let receipt = health.receipt(podID: settings.podID, record: record) {
                Image(systemName: "heart").font(.system(size: 15)).foregroundStyle(Theme.red)
                Text("Saved to Apple Health").font(.subheadline)
                Spacer(minLength: 8)
                Text(receipt.date.formatted(date: .omitted, time: .shortened))
                    .font(.mono(11, relativeTo: .caption2)).foregroundStyle(Theme.text2)
                Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.green)
            } else {
                Image(systemName: "heart").font(.system(size: 15)).foregroundStyle(Theme.amber)
                Text(health.isSyncing ? "Saving to Apple Health…" : "Not saved").font(.subheadline)
                Spacer(minLength: 8)
                Button("Retry") {
                    Task {
                        await health.syncRecent(
                            api: HealthSyncService.frozenClient(), podID: settings.podID,
                            side: profile.defaultSide, demo: APIBackend.current.isDemo)
                    }
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.amber).disabled(health.isSyncing)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .cardSurface(radius: 18)
    }

    private var watchRow: some View {
        Button {
            Haptics.tap()
            showWatch = true
        } label: {
            SettingsRow(
                "Compare with Apple Watch", icon: "applewatch", chevron: true, height: 52, titleFont: .subheadline
            ) {
                if !usesPodStages, let value = nightlyAgreement[calendar.startOfDay(for: selectedDate)] {
                    RowValue("\(Int(value.rounded()))%", mono: true)
                }
            }
            .cardSurface(radius: 18)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("compareWatch")
        .accessibilityHint("Shows stages and vitals beside the Watch's")
    }

    private var stagesRow: some View {
        Button {
            Haptics.tap()
            showStages = true
        } label: {
            SettingsRow(
                "Compare stage models", subtitle: "Experimental", icon: "chart.bar.doc.horizontal", chevron: true,
                height: 52, titleFont: .subheadline
            )
            .cardSurface(radius: 18)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("compareStageModels")
        .accessibilityHint("Shows the Watch, the pod's rules and an experimental model side by side")
    }

    // MARK: Week

    private var weekContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if APIBackend.current != .freeSleep {
                Picker("Week stage source", selection: $nightStageSource) {
                    Text("Pod").tag("pod")
                    Text("This iPhone").tag("phone")
                }
                .pickerStyle(.segmented).accessibilityIdentifier("sleep.weekStageSource")
            }
            if usesPodStages, periodStages.loading { ProgressView("Loading stages for this week…") }
            if usesPodStages, !periodStages.errors.isEmpty {
                Text(
                    "Stages could not be loaded for \(periodStages.errors.count) night(s). Recorded durations and vitals remain available."
                ).font(.footnote).foregroundStyle(Theme.amber)
                Button("Retry week stages") { periodStageRevision += 1 }
            }
            SleepWeekOverview(nights: weekNights, stages: weekStages, selected: selectedDate, calendar: calendar) {
                selectedDate = $0
                Haptics.tap()
            }
            if let record {
                Button(
                    "Open \(selectedDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone)))"
                ) { period = .night }
                .accessibilityIdentifier("sleep.openWeekNight")
                if let summary = weekStages[record.id] {
                    SleepStagesTimelineView(
                        stages: summary.epochs, qualityScore: summary.quality, sourceLabel: summary.source,
                        gapTolerance: usesPodStages ? 0 : 300, showDurations: true)
                }
                NavigationLink("Movement and biometrics") {
                    BiometricsScreen(side: metrics.selectedSide, date: selectedDate, period: .week)
                }
            }
            analysisCard
            if !nightlyAgreement.isEmpty { agreementTrendCard }
        }
    }

    /// Agreement per night, so a change to the stage logic shows up as a shift across the week.
    private var agreementTrendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: "applewatch").font(.caption).foregroundStyle(Theme.text2)
                    Eyebrow("WATCH AGREEMENT")
                }
                Spacer()
                Text(agreement.map { "\(Int($0.rounded()))%" } ?? "—").font(
                    .mono(24, weight: .light, relativeTo: .title2))
            }
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(weekDays, id: \.self) { day in
                        let value = nightlyAgreement[calendar.startOfDay(for: day)]
                        let selected = calendar.isDate(day, inSameDayAs: selectedDate)
                        Button {
                            Haptics.tap()
                            selectedDate = calendar.startOfDay(for: day)
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(value != nil ? Theme.violet.opacity(selected ? 1 : 0.75) : Theme.track)
                                .frame(height: value.map { max(12, 100 * $0 / 100) } ?? 4)
                                .frame(maxWidth: .infinity, maxHeight: 100, alignment: .bottom)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
                        .accessibilityValue(value.map { "\(Int($0.rounded())) percent agreement" } ?? "No Watch data")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .frame(height: 100)
                HStack(spacing: 10) {
                    ForEach(weekDays, id: \.self) { day in
                        Text(nightlyAgreement[calendar.startOfDay(for: day)].map { "\(Int($0.rounded()))" } ?? "·")
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(
                                calendar.isDate(day, inSameDayAs: selectedDate) ? Theme.text1 : Theme.text3)
                    }
                }
                .font(.mono(10, relativeTo: .caption2))
                .accessibilityHidden(true)
            }
        }
        .cardStyle()
    }

    private var analysisCard: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("ON THIS iPHONE")
                Text(
                    "Optional Health sync uses this iPhone’s analysis settings. Pod stages are displayed separately and do not change existing Health entries."
                )
                .font(.footnote).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsRow("Stage model", icon: "cpu", height: 52, titleFont: .subheadline) {
                RowValue(
                    metrics.selectedSide == profile.defaultSide
                        ? stageModels.active?.title ?? "rule-based" : "rule-based", mono: true)
            }
            SettingsRow("Apple Health", icon: "heart", iconColor: Theme.red, height: 52, titleFont: .subheadline) {
                RowValue("\(syncedNights) of 7 nights", mono: true)
                if syncedNights > 0 && syncedNights == recordedNights {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(
                        Theme.green)
                }
            }
            if let agreement {
                SettingsRow("Watch agreement", icon: "applewatch", height: 52, titleFont: .subheadline) {
                    RowValue("\(Int(agreement.rounded()))%", mono: true)
                }
            }
        }
    }

    private var recordedNights: Int {
        Set(metrics.sleepRecords.map { SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar) }).count
    }

    private var syncedNights: Int {
        guard metrics.selectedSide == profile.defaultSide, !isDemo else { return 0 }
        return Set(
            metrics.sleepRecords.filter { health.receipt(podID: settings.podID, record: $0) != nil }
                .map { SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar) }
        ).count
    }

    // MARK: Month

    private var monthContent: some View {
        SleepMonthOverview(
            nights: SleepPeriodSummary.nights(
                days: monthDays, records: monthRecords, vitals: [], side: metrics.selectedSide, calendar: calendar),
            calendar: calendar, loading: monthLoading
        ) { day in
            selectedDate = day
            period = .night
            Haptics.tap()
        }
    }

    private func barsCard<Label: View>(
        days: [Date], hours: [Double], spacing: CGFloat, radius: CGFloat, height: CGFloat,
        @ViewBuilder label: @escaping (Int, Date) -> Label
    ) -> some View {
        let recorded = hours.filter { $0 > 0 }
        let average = recorded.isEmpty ? 0 : recorded.reduce(0, +) / Double(recorded.count)
        let scale = max(8, (hours.max() ?? 0) * 1.1)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("AVG ASLEEP")
                Spacer()
                Text(recorded.isEmpty ? "—" : DisplayTime.duration(Int(average * 3600)))
                    .font(.mono(24, weight: .light, relativeTo: .title2))
            }
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        let value = hours[index]
                        let selected = calendar.isDate(day, inSameDayAs: selectedDate)
                        Button {
                            Haptics.tap()
                            selectedDate = calendar.startOfDay(for: day)
                        } label: {
                            UnevenRoundedRectangle(
                                cornerRadii: .init(
                                    topLeading: radius, bottomLeading: radius,
                                    bottomTrailing: radius, topTrailing: radius),
                                style: .continuous
                            )
                            .fill(value > 0 ? Theme.cool.opacity(selected ? 1 : 0.75) : Theme.track)
                            .frame(height: value > 0 ? max(radius * 2, height * value / scale) : 4)
                            .frame(maxWidth: .infinity, maxHeight: height, alignment: .bottom)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
                        .accessibilityValue(value > 0 ? DisplayTime.duration(Int(value * 3600)) : "No sleep recorded")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .frame(height: height)
                HStack(spacing: spacing) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in label(index, day) }
                }
                .font(.mono(10, relativeTo: .caption2))
                .accessibilityHidden(true)
            }
        }
        .cardStyle()
    }

    // MARK: Data

    private func move(_ amount: Int) {
        let component: Calendar.Component = period == .night ? .day : period == .week ? .weekOfYear : .month
        let next = calendar.date(byAdding: component, value: amount, to: selectedDate) ?? selectedDate
        selectedDate = min(next, calendar.startOfDay(for: Date()))
        Haptics.tap()
    }

    private func fetchMonth() async {
        let start = monthStart
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let side = metrics.selectedSide
        monthError = nil
        monthLoading = true
        monthRecords = []
        do {
            let records = try await APIBackend.current.createClient().getSleepRecords(
                side: side, start: start, end: calendar.date(byAdding: .hour, value: 12, to: end) ?? end)
            guard side == metrics.selectedSide, start == monthStart else { return }
            monthRecords = records.filter {
                $0.side == side.rawValue && SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar) >= start
                    && SleepCalendar.nightDate(for: $0.enteredBedDate, calendar: calendar) < end
            }
        } catch {
            guard side == metrics.selectedSide, start == monthStart else { return }
            monthRecords = []
            monthError = error.localizedDescription
        }
        if side == metrics.selectedSide, start == monthStart { monthLoading = false }
    }

    private func refresh() async {
        refreshRevision += 1
        let revision = refreshRevision
        metrics.timeZone = settings.timeZone
        let weekStart = calendar.startOfWeek(for: selectedDate)
        if metrics.selectedWeekStart != weekStart { metrics.selectedWeekStart = weekStart }
        await metrics.fetchAll()
        guard revision == refreshRevision else { return }
        weekSummaries = SleepPeriodSummary.nights(
            days: weekDays, records: metrics.sleepRecords, vitals: metrics.vitalsRecords, side: metrics.selectedSide,
            calendar: calendar)
        weekSummarySide = metrics.selectedSide
        weekSummaryStart = metrics.selectedWeekStart
        // The store holds one model, used for Health sync of the wearer's side; the partner's side never replaces it.
        if !isDemo {
            await stageModels.refreshPodModel(api: APIBackend.current.createClient(), side: profile.defaultSide)
        }
        let calibration = try? await APIBackend.current.createClient().getCalibrationStatus(side: metrics.selectedSide)
        guard revision == refreshRevision else { return }
        analyzer.analyze(
            vitals: vitals, movement: metrics.movementRecords,
            calibrationQuality: calibration?.piezo?.qualityScore ?? 0,
            model: metrics.selectedSide == profile.defaultSide
                ? record.flatMap { stageModels.staging(enteredBed: $0.enteredBedDate, leftBed: $0.leftBedDate) } : nil)
        let weekAnalyzer = SleepAnalyzer()
        var localSummaries: [Int: SleepNightStageSummary] = [:]
        var nights: [(record: SleepRecord, epochs: [SleepAnalyzer.SleepEpoch], vitals: [VitalsRecord])] = []
        for night in metrics.sleepRecords where night.leftBedDate > night.enteredBedDate {
            let records = metrics.vitalsRecords.filter {
                $0.date >= night.enteredBedDate && $0.date < night.leftBedDate
            }
            weekAnalyzer.analyze(
                vitals: records, movement: metrics.movementRecords,
                calibrationQuality: calibration?.piezo?.qualityScore ?? 0,
                model: metrics.selectedSide == profile.defaultSide
                    ? stageModels.staging(enteredBed: night.enteredBedDate, leftBed: night.leftBedDate) : nil)
            nights.append((night, weekAnalyzer.stages, weekAnalyzer.filterOutliers(vitals: records)))
            localSummaries[night.id] = .init(
                epochs: weekAnalyzer.stages, quality: weekAnalyzer.stages.isEmpty ? nil : weekAnalyzer.qualityScore,
                source: "This iPhone")
        }
        localWeekStages = localSummaries
        var nightly: [Double?]
        if isDemo {
            nightly = nights.map {
                WatchComparison.demo(record: $0.record, epochs: $0.epochs, vitals: $0.vitals).stages.percent
            }
            agreement = WatchComparison.mean(nightly.compactMap { $0 })
        } else if canCompareWatch {
            (agreement, nightly) = await health.weekAgreement(nights: nights.map(\.epochs))
        } else {
            (agreement, nightly) = (nil, [])
        }
        guard revision == refreshRevision else { return }
        // Keyed by day; the day's longest record is the night, matching what the Night view shows.
        let byDay = Dictionary(grouping: zip(nights, nightly).map { ($0.record, $1) }) {
            SleepCalendar.nightDate(for: $0.0.enteredBedDate, calendar: calendar)
        }
        nightlyAgreement = byDay.compactMapValues { entries in
            entries.max { $0.0.sleepPeriodSeconds < $1.0.sleepPeriodSeconds }?.1
        }
        if DebugRoute.current == "watch", record != nil, !showWatch { showWatch = true }
        if DebugRoute.current == "stages", record != nil, !showStages { showStages = true }
    }
}
