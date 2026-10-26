import Foundation
import Observation

/// A generation token prevents a late read from repopulating another person's evidence.
@MainActor @Observable final class PersonalEvidenceWorkspace {
    private(set) var facts: [SleepFact] = []
    private(set) var summary: String?
    private(set) var hasObservations = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var example = false
    private var generation = UUID()

    func invalidate() {
        generation = UUID(); facts = []; summary = nil; hasObservations = false; loading = false; error = nil; example = false
    }
    func load(side: String, days: Int, reader: @MainActor () async throws -> NativePodEvidence) async {
        invalidate(); loading = true
        let request = generation
        defer { if request == generation { loading = false } }
        do {
            let value = try await reader()
            try Task.checkCancellation()
            guard request == generation else { return }
            guard value.side == side, value.days == days, value.start < value.end,
                  TimeZone(identifier: value.timeZone) != nil, value.facts.count <= 50,
                  Set(value.facts.map(\.id)).count == value.facts.count,
                  value.facts.allSatisfy({ $0.id.hasPrefix("pod.") && $0.text.utf8.count <= 4000 }) else {
                throw PodError.message("The Pod summary does not match the selected person and range.")
            }
            facts = value.facts.map { SleepFact(id: $0.id, text: $0.text) }; summary = value.summary; hasObservations = value.hasObservations
        } catch {
            if request == generation && !Task.isCancelled { self.error = "Pod summary is unavailable. Check the connection or use Health history alone. \(error.localizedDescription)" }
        }
    }
    func showExample(side: String, days: Int, empty: Bool = false) {
        invalidate(); example = true
        facts = [.init(id: "pod.range", text: "Example only · \(side) side · \(days)-day range. These are synthetic records, not readings from your bed."),
                 .init(id: "pod.coverage", text: empty ? "No eligible completed presence records. Missing dates are unknown, not zero sleep."
                    : "Six eligible records across five wake dates. Gaps are unknown; bed presence is not measured sleep."),
                 .init(id: "pod.processing", text: "Example processing provenance: original observations from two configurations. Means are not one consistently reprocessed baseline.")]
        if !empty { facts.append(.init(id: "pod.presence", text: "Mean reported presence: 430 minutes per recorded wake date, preserving exits. Presence does not establish sleep stages or quality.")) }
        summary = empty ? "No eligible completed presence records." : "Example: 430 average presence minutes across five recorded wake dates."
        hasObservations = !empty
    }
}
