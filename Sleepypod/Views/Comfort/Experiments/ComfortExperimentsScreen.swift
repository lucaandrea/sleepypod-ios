import SwiftUI

/// Uses the same plan → review → explicit control sequence as the web app.
struct ComfortExperimentsScreen: View {
    @Environment(\.scenePhase) private var phase
    @Bindable var model: ComfortExperimentWorkspace
    var synthetic = false
    @State private var firstDate = Date()
    @State private var variant = 69
    @AccessibilityFocusState private var focused: String?
    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if synthetic { Section { Label("Practice data · no bed commands", systemImage: "flask").foregroundStyle(Theme.amber) } }
                if model.busy { Section { ProgressView("Checking your comparison…") } }
                if let error = model.error {
                    Section {
                        Text(error).accessibilityFocused($focused, equals: "error").accessibilityIdentifier("experiments.error")
                        if let detail = model.detail, model.execution?.state == "not_admitted" {
                            Text(detail.scope.kind == "personal"
                                 ? "Ask your household owner to open Autopilot → Personal comfort. Qualification & activation contains the attended checks. Under Preview night reports, they can open each matching night and choose Review this night. Your saved comparison stays available."
                                 : "Open Autopilot → Personal comfort. Qualification & activation contains the attended checks. Under Preview night reports, open each matching night and choose Review this night. Your saved comparison stays available.")
                                .font(.footnote).foregroundStyle(Theme.text2).accessibilityIdentifier("experiments.qualificationHelp")
                        }
                    }
                }
                if let notice = model.notice { Section { Text(notice).accessibilityIdentifier("experiments.notice") } }
                if model.pending != nil {
                    Section { action("Check saved result", id: "reconcile") { await model.reconcile() } }
                } else if let review = model.review {
                    Section("Review your comparison") {
                        Text("\(review.plan.context.baselineF)°F and \(review.plan.variantF)°F").font(.title2.bold())
                            .accessibilityFocused($focused, equals: "review").accessibilityIdentifier("experiments.review")
                        Text("16 scheduled nights, including settling nights. Your wake routine stays separate.")
                        Text("Saving this plan does not change your bed temperature.").font(.footnote).foregroundStyle(Theme.text2)
                    }
                    ComfortExperimentScheduleSection(plan: review.plan)
                    Section {
                        action("Save comparison plan", id: "save", enabled: model.canConfirmPlan) { await model.savePlan() }
                        Button("Keep editing") { model.discardReview(); Task { await model.open() } }.disabled(model.busy)
                        Text("Review expires in \(model.secondsRemaining) seconds.").font(.footnote).foregroundStyle(Theme.text2)
                    }
                } else if let detail = model.detail {
                    ComfortExperimentDetailSections(model: model, detail: detail)
                    Section { action("Back to comparisons", id: "library") { await model.open() } }
                } else if let library = model.library {
                    Section {
                        Text("Find your more comfortable setting").font(.title2.bold()).accessibilityIdentifier("experiments.library")
                        Text("Compare two nearby settings, then tell us how you felt each morning. Your alarm keeps its own warming and vibration.")
                    }
                    Section("Saved comparisons") {
                        if library.experiments.isEmpty { Text("Your first comparison starts with a review of the nights and temperatures.").foregroundStyle(Theme.text2) }
                        ForEach(library.experiments) { item in
                            Button { Task { await model.select(item.id) } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(item.baselineF)°F and \(item.variantF)°F").font(.headline)
                                    Text("From \(item.firstNightDate) · \(item.status == "stopped" ? "Stopped" : "Open saved plan")").font(.subheadline).foregroundStyle(Theme.text2)
                                    if !item.contextCurrent { Text("Routine or assignment needs checking").font(.footnote).foregroundStyle(Theme.amber) }
                                }.padding(.vertical, 4)
                            }.disabled(model.busy).accessibilityIdentifier("experiments.saved.\(item.id)")
                        }
                        if library.nextId != nil { action("Older comparisons", id: "older") { await model.open(older: true) } }
                    }
                    if let context = library.availability.context {
                        Section("Plan a comparison") {
                            Text("Your scheduled setting is \(context.baselineF)°F. Your overnight range is \(context.minimumF)–\(context.maximumF)°F.")
                                .font(.footnote).foregroundStyle(Theme.text2)
                            DatePicker("First night", selection: $firstDate, displayedComponents: .date).environment(\.timeZone, .gmt)
                                .accessibilityIdentifier("experiments.firstDate")
                            Picker("Compare with", selection: $variant) {
                                ForEach(variants(context), id: \.self) { Text("\($0)°F").tag($0) }
                            }.accessibilityIdentifier("experiments.variant")
                            action("Review scheduled nights", id: "preview", enabled: !library.experiments.contains { $0.status == "planned" }) {
                                await model.preview(.init(firstNightDate: MorningJournalDates.key(firstDate, timeZone: "GMT"), variantF: variant))
                            }
                            if library.experiments.contains(where: { $0.status == "planned" }) {
                                Text("Open or stop your existing comparison before starting another.").font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }.disabled(model.busy)
                    } else { Section("Before you begin") { Text(library.availability.reason) } }
                    Section { action("Refresh comparisons", id: "refresh") { await model.open() } }
                } else {
                    Section {
                        Text("Review nearby settings and keep your wake plan intact.")
                        action("Open comparisons", id: "open", enabled: model.enabled) { await model.open() }
                    }
                }
            }
            .onChange(of: model.detail?.record.plan.id) { _, value in
                if value != nil { proxy.scrollTo("experiments.status", anchor: .top) }
            }
            .onChange(of: model.execution?.review?.id) { _, value in
                if value != nil { proxy.scrollTo("experiments.controlReview", anchor: .top) }
            }
        }
        .privacySensitive().scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Comfort comparisons").navigationBarTitleDisplayMode(.inline)
        .task(id: phase) {
            guard phase == .active else { model.suspend(); return }
            await model.open()
            var elapsed = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                model.tick(); elapsed += 1
                if elapsed % 15 == 0 { await model.checkAccess() }
            }
        }
        .onDisappear { model.suspend() }
        .onChange(of: model.review?.reviewId) { _, value in if value != nil { focused = "review" } }
        .onChange(of: model.error) { _, value in if value != nil { focused = "error" } }
        .onChange(of: model.library?.availability.context, initial: true) { _, context in
            guard let context else { return }
            let tomorrow = ComfortExperimentContract.shifted(MorningJournalDates.key(model.currentDate, timeZone: context.timezone), days: 1)
            firstDate = ISO8601DateFormatter().date(from: tomorrow + "T12:00:00Z") ?? .now
            let choices = variants(context)
            variant = choices.contains(context.baselineF - 1) ? context.baselineF - 1 : choices.first ?? context.baselineF
        }
    }
    private func variants(_ context: ComfortExperimentContext) -> [Int] {
        (-2...2).filter { $0 != 0 }.map { context.baselineF + $0 }.filter { (context.minimumF...context.maximumF).contains($0) }
    }
    private func action(_ title: String, id: String, enabled: Bool = true, work: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { await work() } } label: { Text(title).frame(minHeight: 44, alignment: .leading) }
            .disabled(!enabled || model.busy).accessibilityIdentifier("experiments.\(id)")
    }
}

struct ComfortExperimentScheduleSection: View {
    let plan: ComfortExperimentPlan
    var body: some View {
        Section("Scheduled nights") {
            Text("The first night at each setting lets you settle in. The second can count toward your comfort comparison.")
                .font(.footnote).foregroundStyle(Theme.text2)
            DisclosureGroup("See all \(plan.nights.count) nights") {
                ForEach(plan.nights) { night in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(night.date) · \(night.targetF)°F").font(.headline)
                        Text(night.role == "settling" ? "Settling night" : "Comparison night").font(.subheadline)
                        if let window = plan.schedule?.windows.first(where: { $0.date == night.date }) {
                            Text("Comparison \(clock(window.windowStart)) – \(clock(window.windowEnd))").font(.footnote).foregroundStyle(Theme.text2)
                            if let wake = window.wake {
                                Text("Wake warming \(clock(wake.startsAt)) toward \(wake.temperatureF.formatted())°F; vibration \(clock(wake.at)) for \(wake.vibrationSeconds) seconds.")
                                    .font(.footnote).foregroundStyle(Theme.text2)
                            }
                        }
                    }.padding(.vertical, 4)
                }
                if let skipped = plan.schedule?.skipped, !skipped.isEmpty {
                    Text("\(skipped.count) dates were skipped because they did not contain a suitable full scheduled night.").font(.footnote).foregroundStyle(Theme.text2)
                }
            }.accessibilityIdentifier("experiments.nights")
            Text("Times follow \(plan.context.timezone).").font(.footnote).foregroundStyle(Theme.text2)
        }
    }
    private func clock(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: plan.context.timezone); formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}
