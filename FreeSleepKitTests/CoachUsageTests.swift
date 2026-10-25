import Foundation
import Testing
@testable import FreeSleepKit

struct CoachUsageTests {
    @MainActor @Test func sharedDemoCountsSurviveLimitChangesAndNeverInventReportedTokens() throws {
        let demo = DemoCoachUsage()
        let initial = try demo.read()
        #expect(initial.attempts == 4); #expect(initial.completed == 3); #expect(initial.failed == 1)
        #expect(initial.totalTokens == 3950); #expect(initial.tokensReportedFor == 3)
        #expect(initial.averageResponseMilliseconds == 1063)
        _ = try demo.save(.init(monthlyLimit: 0, originalRevision: 0))
        #expect(throws: (any Error).self) { try demo.record() }
        #expect(try demo.read().attempts == 4)
        #expect(throws: (any Error).self) { try demo.save(.init(monthlyLimit: 10, originalRevision: 0)) }
        _ = try demo.save(.init(monthlyLimit: 100, originalRevision: 1))
        for _ in 0..<96 { try demo.record() }
        let final = try demo.read()
        #expect(final.attempts == 100); #expect(final.remaining == 0)
        #expect(final.tokensReportedFor == 3); #expect(final.totalTokens == 3950)
        #expect(final.averageResponseMilliseconds == 1003)
        #expect(throws: (any Error).self) { try demo.record() }
    }
    @MainActor @Test func refreshingKeepsOriginalDraftRevisionUntilExplicitReset() async throws {
        let demo = DemoCoachUsage(); let workspace = CoachUsageWorkspace()
        await workspace.load { try demo.read() }; workspace.limit = 80
        _ = try demo.save(.init(monthlyLimit: 60, originalRevision: 0))
        await workspace.load { try demo.read() }
        #expect(workspace.limit == 80); #expect(workspace.snapshot?.monthlyLimit == 60)
        await workspace.save { change in
            #expect(change.originalRevision == 0); return try demo.save(change)
        }
        #expect(workspace.error?.contains("changed elsewhere") == true); #expect(workspace.hasDraft)
        workspace.reset(); #expect(workspace.limit == 60); #expect(!workspace.hasDraft)
        workspace.limit = 40
        await workspace.save { change in
            #expect(change.originalRevision == 1); #expect(change.monthlyLimit == 40)
            return try demo.save(change)
        }
        #expect(workspace.snapshot?.monthlyLimit == 40); #expect(!workspace.hasDraft)
        workspace.limit = -1; #expect(!workspace.valid)
        workspace.limit = 1001; #expect(!workspace.valid)
        workspace.limit = 0; #expect(workspace.valid)
    }
    @MainActor @Test func staleLoadsAndDuplicateSavesCannotPublishOrEraseNewerEdits() async throws {
        let sample = try DemoCoachUsage().read(); let workspace = CoachUsageWorkspace()
        await workspace.load { workspace.invalidate(); return sample }
        #expect(workspace.snapshot == nil); #expect(!workspace.busy)
        await workspace.load { sample }; workspace.limit = 90
        var saves = 0
        await workspace.save { _ in
            saves += 1
            await workspace.save { _ in saves += 1; return sample }
            workspace.limit = 75
            var response = sample; response.monthlyLimit = 90; response.revision = 1
            return response
        }
        #expect(saves == 1); #expect(workspace.limit == 75); #expect(workspace.hasDraft)
        #expect(workspace.snapshot?.monthlyLimit == 90)
        let task = Task { await workspace.load { try await Task.sleep(for: .milliseconds(200)); return sample } }
        await Task.yield(); task.cancel(); await task.value
        #expect(workspace.snapshot?.monthlyLimit == 90); #expect(workspace.error == nil)
    }
    @MainActor @Test func nativeUsageRequestsPreserveRevisionAndSurfaceConflictsWithoutRetries() async throws {
        let sample = try DemoCoachUsage().read(); let data = try JSONEncoder().encode(sample)
        let fixture = try IntentHTTPFixture { request in
            if request.httpMethod == "POST" { return .init(status: 409, json: #"{"error":{"message":"Refresh usage and reset your draft."}}"#) }
            return .init(data: data)
        }
        defer { fixture.close() }
        let workspace = CoachUsageWorkspace()
        await workspace.load { try await fixture.client.get("ai/usage") }
        #expect(workspace.snapshot == sample); workspace.limit = 50
        await workspace.save { try await fixture.client.postReturning("ai/usage/limit", body: $0) }
        #expect(workspace.error?.contains("reset your draft") == true); #expect(workspace.hasDraft)
        try fixture.expect(0, method: "GET", path: "ai/usage")
        try fixture.expect(1, path: "ai/usage/limit", body: ["monthlyLimit": 50, "originalRevision": 0])
        #expect(fixture.requests.count == 2)
    }
}
