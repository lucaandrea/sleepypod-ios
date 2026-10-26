#if DEBUG
import Foundation

/// Source-generated receipts are labelled examples and can never send a hardware command.
enum NativeCommandExample {
    struct Fixture: Decodable {
        struct Pair: Decodable { let request: NativeControlRequest; let receipt: NativeControlReceipt }
        let synthetic: Bool
        let cases: [String: Pair]
    }
    @MainActor static func service(scenario: String) throws -> NativeControlService {
        guard let url = Bundle.main.url(forResource: "control-receipts-example", withExtension: "json") else { throw NativeControlFailure.invalid }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)); guard fixture.synthetic else { throw NativeControlFailure.invalid }
        let ledger = NativeControlLedger(directory: nil)
        let scope = OwnerConnection.revision
        let names = scenario == "states" ? ["acknowledged", "expired", "rejected", "not_dispatched", "executing", "unknown"] : ["unknown"]
        for name in names {
            guard let pair = fixture.cases[name] else { throw NativeControlFailure.invalid }
            try ledger.append(pair.request, scope: scope); try ledger.save(pair.receipt, scope: scope)
        }
        let client = SyntheticCommandClient(ledger: ledger, scope: scope, scenario: scenario)
        return .init(ledger: ledger, client: { client }, live: { true }, pause: {})
    }
}
@MainActor private final class SyntheticCommandClient: NativeControlClient {
    let ledger: NativeControlLedger
    let scope: [String]
    let scenario: String
    init(ledger: NativeControlLedger, scope: [String], scenario: String) { self.ledger = ledger; self.scope = scope; self.scenario = scenario }
    func available() async throws {}
    func submit(_ request: NativeControlRequest) async throws -> NativeControlReceipt { throw NativeControlFailure.unavailable }
    func read(_ request: NativeControlRequest) async throws -> NativeControlReceipt {
        if scenario == "offline" { throw URLError(.notConnectedToInternet) }
        guard let receipt = try ledger.read(scope: scope).first(where: { $0.id == request.requestId })?.receipt else { throw NativeControlFailure.invalid }
        if scenario != "readback" { return receipt }
        return .init(version: 1, requestId: request.requestId, action: request.action, issuedAt: request.issuedAt, expiresAt: request.expiresAt,
            receivedAt: receipt.receivedAt, finishedAt: receipt.receivedAt + 1, lastDispatchAt: receipt.receivedAt,
            state: "acknowledged", reason: nil, dispatchCount: 1, physicalVerification: "unverified", replayAllowed: false)
    }
}
#endif
