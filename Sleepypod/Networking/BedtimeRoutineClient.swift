import Foundation

protocol BedtimeRoutineClient: Sendable {
    func routines(side: Side) async throws -> BedtimeRoutineBook
    func replace(_ input: BedtimeRoutineChanges) async throws -> BedtimeRoutineReceipt
}
struct CoreBedtimeRoutineClient: BedtimeRoutineClient {
    let transport: CoreRESTClient
    func routines(side: Side) async throws -> BedtimeRoutineBook { try await transport.get("v1/routines", query: ["side": side.rawValue]) }
    func replace(_ input: BedtimeRoutineChanges) async throws -> BedtimeRoutineReceipt { try await transport.post("v1/routines", body: input, returning: BedtimeRoutineReceipt.self) }
}
