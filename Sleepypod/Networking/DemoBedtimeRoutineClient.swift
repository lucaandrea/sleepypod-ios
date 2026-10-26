import CryptoKit
import Foundation

/// Disposable routines are isolated by side and never sent to a controller.
actor DemoBedtimeRoutineClient: BedtimeRoutineClient {
    private var saved: [Side: [BedtimeRoutineSnapshot]] = [:]
    private let canCreate: Bool
    init(canCreate: Bool = true) { self.canCreate = canCreate }
    func routines(side: Side) -> BedtimeRoutineBook { .init(version: 1, side: side, canCreate: canCreate, routines: saved[side] ?? []) }
    func replace(_ input: BedtimeRoutineChanges) throws -> BedtimeRoutineReceipt {
        try input.validate(against: routines(side: input.side))
        var result = saved[input.side] ?? []
        for change in input.changes {
            result.removeAll { $0.dayOfWeek == change.dayOfWeek }
            if let draft = change.replacement?.normalized {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let revision = SHA256.hash(data: try encoder.encode(draft)).map { String(format: "%02x", $0) }.joined()
                result.append(.init(dayOfWeek: change.dayOfWeek, revision: revision, draft: draft))
            }
        }
        saved[input.side] = result
        return .init(version: 1, side: input.side, canCreate: canCreate, routines: result, schedulerApplied: true)
    }
}
