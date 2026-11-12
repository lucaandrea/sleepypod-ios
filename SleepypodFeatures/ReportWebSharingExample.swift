#if DEBUG
import SwiftUI

/// In-memory sharing practice. The live connection factory, archive, Health and provider APIs are unreachable.
public struct ReportWebSharingExample: View {
    @State private var workspace: MorningReportSharingWorkspace
    private let report: PersonalSleepReport
    public init() {
        let scenario = UserDefaults.standard.string(forKey: "uiReportSharingScenario") ?? "ready"
        var example = ReportPresentationExample.report
        if scenario == "update" {
            example.followUps = [.init(id: UUID(), createdAt: example.createdAt.addingTimeInterval(60),
                question: "What does missing coverage mean?", text: "Missing readings remain unknown. [health.recent]",
                provider: .openai, model: "Example model", inputTokens: nil, outputTokens: nil)]
        }
        report = example
        let transport = ExampleReportSharing(scenario: scenario)
        _workspace = State(initialValue: .init(connect: {
            if scenario == "offline" { throw MorningReportSharingFailure.unavailable }
            return .init(address: "https://example-pod.invalid", transport: transport, isCurrent: { true })
        }, protectedData: { true }))
    }
    public var body: some View {
        NavigationStack { ReportWebSharingScreen(report: report, example: true, workspace: workspace) }
    }
}

private actor ExampleReportSharing: MorningReportSharingTransport {
    private let scenario: String
    private var saved: MorningReportSharedCopy?
    init(scenario: String) { self.scenario = scenario }
    func read(id: UUID) async throws -> MorningReportSharedCopy? {
        if scenario == "update", saved == nil {
            let timestamp = Int64(Date.now.timeIntervalSince1970 * 1000)
            saved = .init(receipt: .init(id: id, revision: UUID(), deleted: false,
                createdAt: Int64(ReportPresentationExample.report.createdAt.timeIntervalSince1970 * 1000),
                receivedAt: timestamp, updatedAt: timestamp), document: try MorningReportTransfer.document(ReportPresentationExample.report))
        }
        return saved
    }
    func share(id: UUID, document: Data, expectedRevision: UUID?) async throws -> MorningReportSharedCopy {
        let timestamp = Int64(Date.now.timeIntervalSince1970 * 1000)
        let copy = MorningReportSharedCopy(receipt: .init(id: id, revision: UUID(), deleted: false,
            createdAt: Int64(ReportPresentationExample.report.createdAt.timeIntervalSince1970 * 1000), receivedAt: timestamp, updatedAt: timestamp), document: document)
        saved = copy
        if scenario == "uncertain" { throw MorningReportSharingFailure.uncertain }
        return copy
    }
    func withdraw(id: UUID, expectedRevision: UUID?) async throws -> MorningReportSharedCopy {
        let timestamp = Int64(Date.now.timeIntervalSince1970 * 1000)
        let copy = MorningReportSharedCopy(receipt: .init(id: id, revision: UUID(), deleted: true,
            createdAt: saved?.receipt.createdAt, receivedAt: timestamp, updatedAt: timestamp), document: nil)
        saved = copy; return copy
    }
}
#endif
