import Foundation

protocol BedCareClient: Sendable { func read() async throws -> BedCare }
struct CoreBedCareClient: BedCareClient {
    let transport: CoreRESTClient
    func read() async throws -> BedCare { try await transport.get("health/care") }
}

/// Shift synthetic source-generated observations together; no device is queried.
struct DemoBedCareClient: BedCareClient {
    func read() throws -> BedCare {
        let fixture = try BedCareExample.load()
        guard fixture.synthetic, let original = fixture.cases["attention"] else { throw APIError.invalidResponse(statusCode: 0) }
        let delta = (Date.now.timeIntervalSince1970 * 1000).rounded(.down) - fixture.now
        let checks = original.checks.map { check in
            BedCare.Check(id: check.id, title: check.title, state: check.state, detail: check.detail, nextStep: check.nextStep,
                observedAt: check.observedAt.map { $0 + delta }, expiresAt: check.expiresAt.map { $0 + delta },
                destination: check.destination, evidence: check.evidence)
        }
        return .init(apiVersion: original.apiVersion, generatedAt: original.generatedAt + delta, checks: checks,
                     lastExportAt: original.lastExportAt.map { $0 + delta })
    }
}
