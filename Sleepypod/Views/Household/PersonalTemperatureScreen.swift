import SwiftUI

struct PersonalTemperatureScreen: View {
    @Bindable var model: PersonalTemperatureWorkspace
    @Environment(HouseholdWorkspace.self) private var household
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var reviewing: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if let bed = model.bed {
                        if bed.availability == "ready" { controls; readings; routing(bed) }
                        else { ContentUnavailableView("Controls unavailable", systemImage: "bed.double", description: Text(availability(bed.availability))) }
                    } else if model.refreshing { ProgressView("Refreshing your bed…").padding(40) }
                    else { ContentUnavailableView("Your bed is unavailable", systemImage: "wifi.slash", description: Text("Refresh your personal account to check its connection and assignment.")) }
                    if model.requiresReview {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Bed configuration changed").font(.headline)
                            Text("Review your current assignment and routing before another adjustment.").font(.footnote)
                            Button("Use reviewed configuration") { model.reviewScope() }
                        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    }
                    if let error = model.error {
                        Text(error).font(.footnote).foregroundStyle(Theme.amber).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("personal.temperature.error")
                        Button("Refresh personal account") { Task { await household.refresh() } }
                    }
                    if !household.controlRecoveries.isEmpty {
                        Text("An earlier command needs review in Account. Power off and Stop vibration remain available.")
                            .font(.footnote).foregroundStyle(Theme.amber)
                    }
                    if household.hasUnresolvedPublicationEffects {
                        Text("An earlier routine publication needs receipt review in Account. Power off and Stop vibration remain available.")
                            .font(.footnote).foregroundStyle(Theme.amber)
                    }
                    receipts
                }.padding(16).padding(.bottom, 24)
            }
            .background(Theme.background).navigationTitle(model.connection.session.person.displayName)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.disabled(model.refreshing)
            } }
            .refreshable { await model.refresh() }
            .alert("Confirm you checked the bed", isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } })) {
                Button("I checked the bed") { if let reviewing { model.markReviewed(reviewing) }; reviewing = nil }
                Button("Cancel", role: .cancel) { reviewing = nil }
            } message: { Text("The earlier outcome remains unknown. This allows a new deliberate adjustment; it never resends the saved command.") }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { model.invalidate(); return }
            var ticks = 0
            while !Task.isCancelled {
                if ticks % 5 == 0 { await model.refresh() }
                model.tick(); ticks += 1
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onDisappear { model.invalidate() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.connection.session.assignmentLabel.uppercased()).font(.mono(12)).foregroundStyle(Theme.text2)
                .accessibilityIdentifier("personal.temperature.assignment")
            Picker("Temperature display", selection: $model.display) {
                ForEach(TemperatureDisplay.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(spacing: 20) {
            GeometryReader { geometry in
                TemperatureDialContent(
                    valueText: model.target.map { model.display.text($0, unit: model.unit) } ?? (model.zones.count > 1 ? "Mixed" : "—"),
                    detailText: model.draftTarget == nil ? "Requested temperature" : "Release to apply",
                    stateText: model.draftTarget == nil ? "REQUESTED" : "DRAFT",
                    progress: model.target.map { model.display == .eightSleep ? Double(TemperatureDisplay.level(for: Double($0)) + 10) / 20 : Double($0 - 55) / 55 },
                    tint: model.target.map(TempRamp.labelColor) ?? Theme.neutral,
                    animationValue: model.target.map(Double.init), isEnabled: model.canAdjust,
                    onProgressChange: { model.edit(fraction: $0) },
                    onAdjustment: { delta in Task { await model.step(delta) } },
                    onDragEnded: { Task { await model.commitDraft() } })
                .scaleEffect(min(1, geometry.size.width / 300))
                .position(x: geometry.size.width / 2, y: 150)
            }.frame(height: 300)
            TemperatureActionButtons(powered: model.powered,
                canPower: model.powered != nil && (model.powered == true ? model.canStopPower : model.canAdjust),
                canDecrease: model.canAdjust && (model.target.map { $0 > 55 } ?? false),
                canIncrease: model.canAdjust && (model.target.map { $0 < 110 } ?? false),
                onPower: { Task { await model.submit(.init(kind: "power", powered: model.powered != true)) } },
                onStep: { delta in Task { await model.step(delta) } })
            if model.target == nil { Text("Drag the dial to choose one temperature for your permitted zones.").font(.footnote).foregroundStyle(Theme.text2) }
            Group {
                if textSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) { holdLabel; holdPicker }.frame(maxWidth: .infinity, alignment: .leading)
                } else { HStack { holdLabel; Spacer(); holdPicker } }
            }.font(.callout)
            if model.powered == nil {
                Button("Turn on") { Task { await model.submit(.init(kind: "power", powered: true)) } }.disabled(!model.canAdjust)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { stopButtons }
                VStack(spacing: 12) { stopButtons }
            }.buttonStyle(.bordered).controlSize(.large)
        }
    }
    private var holdLabel: some View { Text("Hold after adjustment").foregroundStyle(Theme.text2) }
    private var holdPicker: some View {
        Picker("Hold after adjustment", selection: $model.holdMinutes) {
            Text("30 min").tag(30); Text("1 hr").tag(60); Text("2 hr").tag(120); Text("8 hr").tag(480)
        }.labelsHidden().fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private var stopButtons: some View {
        Button("Power off", systemImage: "power") { Task { await model.submit(.init(kind: "power", powered: false)) } }.disabled(!model.canStopPower)
        Button("Stop vibration", systemImage: "stop.circle") { Task { await model.submit(.init(kind: "vibration.clear")) } }.disabled(!model.canStopVibration)
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if textSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 8) { readingsHeading; readingsStatus } }
                else { HStack { readingsHeading; Spacer(); readingsStatus } }
            }
            ForEach(model.zones) { zone in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(zone.side.displayName).font(.headline); Spacer(); Text(zone.reportedPowered.map { $0 ? "On" : "Off" } ?? "Power unknown").font(.caption) }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { values(zone) }
                        VStack(alignment: .leading, spacing: 12) { values(zone) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Reported values come from the controller. A command receipt alone does not confirm a physical change.").font(.footnote).foregroundStyle(Theme.text2)
        }.cardStyle().accessibilityIdentifier("personal.temperature.readings")
    }
    private var readingsHeading: some View { Text("BED READINGS").font(.mono(12)).foregroundStyle(Theme.text2) }
    private var readingsStatus: some View {
        Text(model.readingsCurrent ? "Current report" : "Unavailable").font(.caption).foregroundStyle(model.readingsCurrent ? Theme.green : Theme.text2)
    }
    @ViewBuilder private func values(_ zone: PersonalBed.Zone) -> some View {
        reading("Measured", value: zone.measuredTemperatureF)
        reading("Reported target", value: zone.reportedTargetF)
        reading("Requested", value: zone.requestedTargetF)
    }
    private func reading(_ label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.text2)
            Text(value.map { TemperatureConversion.displayTemp(Int($0.rounded()), format: model.unit) } ?? "—")
                .font(.mono(22)).foregroundStyle(value.map { TempRamp.labelColor(Int($0.rounded())) } ?? Theme.text3)
        }
    }
    private func routing(_ bed: PersonalBed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YOUR BED ROUTING").font(.mono(12)).foregroundStyle(Theme.text2)
            Text("Temperature · \(bed.routing.temperature.map(\.displayName).joined(separator: " + "))")
            Text("Scheduled vibration · \(bed.routing.scheduledVibration.map(\.displayName).joined(separator: " + "))")
                .accessibilityIdentifier("personal.temperature.wakeRouting")
            Text("Routing is reported by the controller; wake-up vibration still needs a physical check. Weekly routine edits remain drafts.").font(.footnote).foregroundStyle(Theme.text2)
        }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }
    private var receipts: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.attempts.isEmpty {
                Text("RECENT COMMANDS").font(.mono(12)).foregroundStyle(Theme.text2)
                ForEach(model.attempts.reversed()) { attempt in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(attempt.request.action.label).font(.headline)
                        Text(attempt.receipt?.message ?? "Awaiting a verified receipt. The exact request is saved and will not be resent.").font(.footnote)
                        Text("Targets · \(attempt.authorizedZones.map(\.displayName).joined(separator: " + "))").font(.caption).foregroundStyle(Theme.text2)
                        Button("Check receipt") { Task { await model.reconcile(attempt.id) } }
                        if attempt.needsReview {
                            Button("Review after checking the bed") { reviewing = attempt.id }.disabled(!model.canReview(attempt))
                        } else if attempt.reviewedAt != nil { Text("Reviewed · original outcome unchanged").font(.caption).foregroundStyle(Theme.text2) }
                    }.frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                }
            }
        }
    }
    private func availability(_ value: String) -> String {
        switch value {
        case "unassigned": "No bed side is assigned to this account. Your weekly routine remains a private draft."
        case "configuration_changed": "Your account and bed configuration differ. Refresh the personal account before continuing."
        default: "Personal controls are not enabled on this controller."
        }
    }
}
