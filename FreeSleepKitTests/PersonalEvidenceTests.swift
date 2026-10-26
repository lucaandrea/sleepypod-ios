import Foundation
import Testing
@testable import FreeSleepKit

@MainActor struct PersonalEvidenceTests {
    private func evidence(_ side: String = "right", days: Int = 30) -> NativePodEvidence {
        .init(side: side, days: days, timeZone: "America/Los_Angeles", start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2000),
              facts: [.init(id: "pod.presence", text: "Recorded presence, not measured sleep.")], summary: "Presence only.", hasObservations: true)
    }
    @Test func exactScopeAndNoDataRemainDistinctFromUnavailable() async {
        let model = PersonalEvidenceWorkspace()
        await model.load(side: "right", days: 30) { evidence() }
        #expect(model.hasObservations); #expect(model.error == nil); #expect(model.facts.count == 1)
        await model.load(side: "left", days: 30) { evidence() }
        #expect(!model.hasObservations); #expect(model.error != nil); #expect(model.facts.isEmpty)
        model.showExample(side: "right", days: 7, empty: true)
        #expect(model.example); #expect(!model.hasObservations); #expect(model.error == nil)
    }
    @Test func lateEvidenceAndCancelledReadsCannotRepopulateAnotherScope() async {
        let model = PersonalEvidenceWorkspace(), gate = EvidenceGate()
        let operation = Task { await model.load(side: "right", days: 30) { await gate.wait(); return evidence() } }
        await gate.waitHeld(); model.invalidate(); await gate.release(); await operation.value
        #expect(model.facts.isEmpty); #expect(!model.loading)
        let cancelledGate = EvidenceGate()
        let cancelled = Task { await model.load(side: "right", days: 30) { await cancelledGate.wait(); return evidence() } }
        await cancelledGate.waitHeld(); cancelled.cancel(); await cancelledGate.release(); await cancelled.value
        #expect(model.facts.isEmpty); #expect(model.error == nil)
    }
    @Test func reviewedModelReplyIsDiscardedAfterScopeOrQuestionChangesOrCancellation() async throws {
        for change in ["scope", "question", "cancel", "none"] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = EvidenceGate(), scope = EvidenceValidity()
            let defaults = UserDefaults(suiteName: "report-\(UUID().uuidString)")!
            let model = IntelligenceWorkspace(defaults: defaults, store: .init(directory: directory), generateModel: { _ in
                await gate.wait(); return .init(text: "Synthetic reply", model: "test")
            })
            await AppMode.$suppliedBackend.withValue("sleepypod-core") {
                model.generate(facts: [.init(id: "pod.presence", text: "Presence only")], consent: false, sourceName: "Pod right", valid: { scope.valid })
                await gate.waitHeld()
                if change == "scope" { scope.valid = false }
                if change == "question" { model.question = "Another question" }
                if change == "cancel" { model.cancel() }
                await gate.release()
                while model.reportInProgress { await Task.yield() }
            }
            #expect(model.archive.reports.count == (change == "none" ? 1 : 0))
            if change == "none" { #expect(model.archive.reports.first?.source == "Pod right") }
        }
    }
    @Test func externalModelsRequireRequestConsentAndDemoCannotDispatch() async {
        let gate = EvidenceGate(), defaults = UserDefaults(suiteName: "consent-\(UUID().uuidString)")!
        defaults.set("ollama", forKey: "intelligence.provider")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = IntelligenceWorkspace(defaults: defaults, store: .init(directory: directory), generateModel: { _ in
            await gate.wait(); return .init(text: "Synthetic reply", model: "test")
        })
        let facts = [SleepFact(id: "pod.presence", text: "Presence only")]
        AppMode.$suppliedBackend.withValue("demo") {
            model.generate(facts: facts, consent: true); #expect(!model.reportInProgress)
        }
        await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            model.generate(facts: facts, consent: false); #expect(!model.reportInProgress)
            model.generate(facts: facts, consent: true)
            await gate.waitHeld(); await gate.release()
            while model.reportInProgress { await Task.yield() }
        }
        #expect(model.archive.reports.count == 1)
    }
}
@MainActor private final class EvidenceValidity { var valid = true }
private actor EvidenceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
