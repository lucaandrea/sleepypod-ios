import Foundation
import Observation

@MainActor @Observable final class SleeperPreferencesWorkspace {
    private enum Scope: Equatable { case bed, side(Side), name(Side) }
    private let client: any SleeperPreferencesClient
    var draft: SleeperPreferencesSnapshot?
    private(set) var saved: SleeperPreferencesSnapshot?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var receipt: String?
    private(set) var mustReload = false
    private(set) var occupancy: SensorOccupancy?
    private(set) var occupancyReceivedAt: Date?
    private(set) var occupancyError: String?
    private var readingOccupancy = false
    var dirty: Bool { draft != saved }
    init(client: any SleeperPreferencesClient) { self.client = client }
    func presenceAvailable(_ side: Side, now: Date = .now) -> Bool {
        occupancyError == nil && SensorObservation.fresh(occupancyReceivedAt, age: 25, now: now) && occupancy?.side(side).available == true
    }
    func load(discard: Bool = false) async {
        guard !busy, !dirty || discard else { return }
        busy = true; defer { busy = false }
        do {
            let value = try await client.settings(); try Task.checkCancellation()
            saved = value; draft = value; error = nil; receipt = nil; mustReload = false
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func refreshOccupancy() async {
        guard !readingOccupancy else { return }
        readingOccupancy = true; defer { readingOccupancy = false }
        do {
            let value = try await client.occupancy(); try Task.checkCancellation()
            occupancy = value; occupancyReceivedAt = .now; occupancyError = nil
        } catch { if !Task.isCancelled { occupancyError = error.localizedDescription } }
    }
    func observePresence() async {
        while !Task.isCancelled {
            await refreshOccupancy()
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
        }
    }
    func saveBed() async {
        guard let draft, let saved else { return }
        if let issue = draft.device.issue { error = issue; return }
        await perform(.bed, patch: .init(fields: draft.device.fields.filter { saved.device.fields[$0.key] != $0.value }))
    }
    func saveSide(_ side: Side) async {
        guard let draft, let saved else { return }
        if let issue = draft.sides[side].issue { error = issue; return }
        await perform(.side(side), patch: draft.sides[side].patch(from: saved.sides[side]))
    }
    func saveName(_ side: Side, name: String) async {
        guard let saved else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft?.sides[side].name = trimmed
        guard !trimmed.isEmpty, trimmed.utf16.count <= 20 else { error = "Names must be 1–20 characters."; return }
        guard trimmed != saved.sides[side].name else { return }
        await perform(.name(side), patch: .init(fields: ["name": .string(trimmed)]))
    }
    // Preflight compares edited fields; readback updates only the saved section and untouched drafts.
    private func perform(_ scope: Scope, patch: SettingsFieldPatch) async {
        guard !busy, !mustReload, !patch.isEmpty, let original = saved else { return }
        busy = true; error = nil; receipt = nil
        var sent = false
        defer { busy = false }
        do {
            let current = try await client.settings()
            guard !patch.conflicts(original: fields(original, scope), current: fields(current, scope)) else {
                error = "A setting you edited changed on the Pod. Reload and review before saving."; mustReload = true; return
            }
            if case .side(let side) = scope {
                let next = try current.sides[side].merging(patch)
                if let issue = next.issue { error = issue; return }
                if (next.autoOnEnabled && !current.sides[side].autoOnEnabled) || (next.autoOffEnabled && !current.sides[side].autoOffEnabled) {
                    let observed = try await client.occupancy()
                    occupancy = observed; occupancyReceivedAt = .now; occupancyError = nil
                    guard observed.side(side).available else { error = "Presence is unavailable for this side. Calibrate it and refresh before enabling presence actions."; return }
                }
            }
            try Task.checkCancellation()
            sent = true
            switch scope {
            case .bed: try await client.saveBed(patch)
            case .side(let side), .name(let side): try await client.saveSide(side, patch: patch)
            }
            receipt = "Settings saved."
            let next = try await client.settings(); try Task.checkCancellation()
            accept(next, scope: scope, original: original)
        } catch {
            mustReload = sent
            if receipt != nil { self.error = "Save was acknowledged, but readback failed. Reload before continuing. \(error.localizedDescription)" }
            else if sent { self.error = "Save was not confirmed. Reload before retrying. \(error.localizedDescription)" }
            else if !Task.isCancelled { self.error = "No change was sent. \(error.localizedDescription)" }
        }
    }
    private func fields(_ snapshot: SleeperPreferencesSnapshot, _ scope: Scope) -> [String: SettingsFieldValue] {
        switch scope {
        case .bed: snapshot.device.fields
        case .side(let side), .name(let side): snapshot.sides[side].fields
        }
    }
    private func accept(_ next: SleeperPreferencesSnapshot, scope: Scope, original: SleeperPreferencesSnapshot) {
        guard var edited = draft else { return }
        if scope == .bed || edited.device == original.device { edited.device = next.device }
        for side in Side.allCases {
            if scope == .side(side) || edited.sides[side] == original.sides[side] { edited.sides[side] = next.sides[side] }
            else if scope == .name(side) { edited.sides[side].name = next.sides[side].name }
        }
        saved = next; draft = edited; mustReload = false
    }
}
