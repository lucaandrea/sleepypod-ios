import Foundation

struct ArrangementTransitionReceipt: Codable, Equatable, Sendable {
    let operationId: String
    let reviewId: String
    let state: String
    let admissionRevision: Int
    let createdAt: Int64
    let committedAt: Int64?
    let hardware: String
    static let fields: Set<String> = ["operationId", "reviewId", "state", "admissionRevision", "createdAt", "committedAt", "hardware"]
    func validate() throws {
        guard [operationId, reviewId].allSatisfy(HouseholdValidation.identifier), ["held", "committed"].contains(state),
              HouseholdValidation.revision(admissionRevision), PersonalControlRequest.validInstant(createdAt),
              (state == "held") == (committedAt == nil),
              committedAt.map({ PersonalControlRequest.validInstant($0) && $0 >= createdAt }) ?? true,
              hardware == "held_for_runtime_recovery" else { throw HouseholdFailure.invalid }
    }
}

/// The caller still reads current status after an accepted mutation; a response cannot reopen controls.
enum ArrangementMaintenanceResult: Sendable {
    enum Services: String, Codable, Sendable { case resumed, unavailable, unchangedByReplay = "unchanged_by_replay" }
    case activated(ArrangementTransitionReceipt, recovered: Bool, replayed: Bool)
    case restarted(ArrangementRestartReceipt, replayed: Bool)
    case recovered(ArrangementRecoveryReceipt, services: Services, replayed: Bool)
    case cancelled(ArrangementCancellationReceipt, services: Services, replayed: Bool)

    private struct Envelope<Receipt: Decodable>: Decodable {
        let receipt: Receipt
        let replayed: Bool
        let recovered: Bool?
        let automaticServices: Services?
    }
    static func decodeExact(_ data: Data, request: ArrangementMaintenanceRequest) throws -> Self {
        let object = try ArrangementJSON.object(data)
        let fields: Set<String> = request.action == .activate ? ["receipt", "recovered", "replayed"]
            : request.action == .restart ? ["receipt", "replayed"] : ["receipt", "automaticServices", "replayed"]
        try ArrangementJSON.keys(object, fields)
        switch request.action {
        case .activate:
            try ArrangementJSON.keys(object["receipt"], ArrangementTransitionReceipt.fields)
            let reply = try JSONDecoder().decode(Envelope<ArrangementTransitionReceipt>.self, from: data)
            try reply.receipt.validate()
            guard reply.receipt.operationId == request.requestId, reply.receipt.reviewId == request.referenceId,
                  let recovered = reply.recovered else { throw HouseholdFailure.invalid }
            return .activated(reply.receipt, recovered: recovered, replayed: reply.replayed)
        case .restart:
            try ArrangementJSON.keys(object["receipt"], ArrangementRestartReceipt.fields)
            let reply = try JSONDecoder().decode(Envelope<ArrangementRestartReceipt>.self, from: data)
            try reply.receipt.validate()
            guard reply.receipt.requestId == request.requestId, reply.receipt.operationId == request.referenceId else { throw HouseholdFailure.invalid }
            return .restarted(reply.receipt, replayed: reply.replayed)
        case .recover:
            try ArrangementJSON.keys(object["receipt"], ArrangementRecoveryReceipt.fields)
            let reply = try JSONDecoder().decode(Envelope<ArrangementRecoveryReceipt>.self, from: data)
            try reply.receipt.validate()
            guard reply.receipt.requestId == request.requestId, reply.receipt.operationId == request.referenceId,
                  let services = reply.automaticServices else { throw HouseholdFailure.invalid }
            return .recovered(reply.receipt, services: services, replayed: reply.replayed)
        case .cancel:
            try ArrangementJSON.keys(object["receipt"], ArrangementCancellationReceipt.fields)
            let reply = try JSONDecoder().decode(Envelope<ArrangementCancellationReceipt>.self, from: data)
            try reply.receipt.validate()
            guard reply.receipt.requestId == request.requestId, reply.receipt.operationId == request.referenceId,
                  let services = reply.automaticServices else { throw HouseholdFailure.invalid }
            return .cancelled(reply.receipt, services: services, replayed: reply.replayed)
        }
    }
}
