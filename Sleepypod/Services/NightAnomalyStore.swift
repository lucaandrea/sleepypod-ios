import Foundation
import Observation
import UIKit
import FreeSleepKit

/// Local, owner-scoped model lifecycle. Reading or reviewing data never changes the bed or trains implicitly.
@MainActor @Observable
final class NightAnomalyStore {
    private struct Saved: Codable { let scope: String; let model: NightAnomalyModel }
    private let file: URL
    private var scope = ""
    private var generation = UUID()
    private(set) var model: NightAnomalyModel?
    private(set) var verified = false
    private(set) var nights: [NightAnomalyObservation] = []
    private(set) var exclusions: [String: Int] = [:]
    private(set) var reviewed: [String: String] = [:]
    private(set) var busy = false
    private(set) var message: String?
    private(set) var loaded = false
    var selectedSource = ""
    var includeVitals = false
    var assessment: NightAnomalyModel.Assessment?

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NightModels", isDirectory: true).appendingPathComponent("baseline.json")
    }

    var sources: [String] { Array(Set(nights.map(\.sourceID))).sorted { sourceName($0) < sourceName($1) } }
    var candidates: [NightAnomalyObservation] { nights.filter { $0.sourceID == selectedSource } }
    var selected: [NightAnomalyObservation] { candidates.filter { reviewed[$0.id] == $0.reviewToken } }
    var canTrain: Bool { loaded && !busy && selected.count >= NightAnomalyModel.minimumNights && !PersonalWorkspaceBoundary.isActive }
    var status: String { busy ? "Working locally" : model == nil ? "Needs reviewed nights" : verified ? "Baseline ready" : "Refresh to verify" }
    func sourceName(_ source: String) -> String { nights.first { $0.sourceID == source }?.sourceName ?? "Health source" }

    func activate(scope newScope: String) {
        guard newScope != scope else { return }
        generation = UUID(); scope = newScope; model = nil; verified = false; nights = []; exclusions = [:]
        reviewed = [:]; loaded = false; message = nil; assessment = nil; selectedSource = ""; busy = false
        guard !PersonalWorkspaceBoundary.isActive, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
            guard saved.scope == scope else { return }
            try saved.model.validate(); model = saved.model
        } catch { message = "The saved baseline could not be validated. Refresh and train a new one." }
    }

    func refresh(health: HealthSyncService, calendar: Calendar, expectedScope: String, now: Date = .now) async {
        activate(scope: expectedScope)
        guard !busy, !APIBackend.current.isDemo, !PersonalWorkspaceBoundary.isActive else { return }
        let operation = UUID(); generation = operation; busy = true; verified = false; assessment = nil; message = nil
        defer { if generation == operation { busy = false } }
        do {
            let audit = try await NightAnomalyHealthReader.read(health: health, calendar: calendar, now: now)
            guard generation == operation, scope == expectedScope, !Task.isCancelled, !PersonalWorkspaceBoundary.isActive else { return }
            accept(audit, now: now)
        } catch {
            if generation == operation { loaded = false; message = error.localizedDescription }
        }
    }

    /// A fresh audit must reproduce every training reference before a saved baseline can be used.
    func accept(_ audit: NightAnomalyDataset.Audit, now: Date) {
        nights = audit.nights; exclusions = audit.exclusions; loaded = true; assessment = nil
        reviewed = reviewed.filter { id, token in nights.contains { $0.id == id && $0.reviewToken == token } }
        if !sources.contains(selectedSource) { selectedSource = model?.sourceID ?? nights.first?.sourceID ?? "" }
        guard let model else { return }
        verified = model.referencesMatch(nights) && model.trainedAt <= now
        guard verified else { message = "Some baseline recordings changed or are no longer readable. Review the refreshed nights and retrain."; return }
        guard now.timeIntervalSince(model.referenceEnd) <= 45 * 86400 else {
            verified = false; message = NightAnomalyModel.Failure.staleBaseline.localizedDescription; return
        }
        assessReviewedNight(now: now)
    }

    private func assessReviewedNight(now: Date) {
        assessment = nil
        guard let model, verified else { return }
        guard let latest = nights.filter({ $0.sourceID == model.sourceID && $0.start >= model.referenceEnd && model.referenceTokens[$0.id] == nil }).max(by: { $0.end < $1.end }) else {
            message = "Baseline verified. A later complete night is needed for an independent comparison."; return
        }
        guard reviewed[latest.id] == latest.reviewToken else {
            message = "Review the latest candidate as an actual complete night to compare it with your baseline."; return
        }
        do { assessment = try model.assess(latest, now: now) }
        catch { verified = false; message = error.localizedDescription }
    }

    func review(_ night: NightAnomalyObservation, confirmed: Bool) {
        guard loaded, !busy, candidates.contains(night), !PersonalWorkspaceBoundary.isActive else { return }
        if confirmed { reviewed[night.id] = night.reviewToken } else { reviewed[night.id] = nil }
        if verified { assessReviewedNight(now: .now) }
    }

    func train(now: Date = .now, currentScope: @MainActor () -> String) async {
        guard canTrain, currentScope() == scope else { return }
        let operation = UUID(); generation = operation; let originalScope = scope, observations = selected, useVitals = includeVitals
        busy = true; message = nil
        defer { if generation == operation { busy = false } }
        do {
            let candidate = try await Task.detached(priority: .userInitiated) { try NightAnomalyModel.fit(observations, now: now, includeVitals: useVitals) }.value
            guard generation == operation, scope == originalScope, currentScope() == originalScope, !Task.isCancelled, !PersonalWorkspaceBoundary.isActive,
                  candidate.referencesMatch(nights) else { return }
            let data = try JSONEncoder().encode(Saved(scope: scope, model: candidate))
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            var protected = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protected.setResourceValues(values)
            model = candidate; verified = true; assessment = nil
            message = "Trained privately. Earlier nights fit the model; later reference nights calibrate its score. The next complete night will provide a new comparison."
        } catch { if generation == operation { message = error.localizedDescription } }
    }

    func cancel() { generation = UUID(); busy = false }

    func delete() {
        cancel()
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            model = nil; verified = false; assessment = nil; message = "Local baseline removed. Health records were not changed."
        } catch { message = "Could not remove the local baseline: \(error.localizedDescription)" }
    }
}
