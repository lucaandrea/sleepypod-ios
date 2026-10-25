import Foundation
import HealthKit

@MainActor
protocol HealthSampleStore {
    func canWrite(heartRate: Bool) -> Bool
    func existing(pod: String, side: BedSide, range: DateInterval, heartRate: Bool) async throws -> [HKSample]
    func save(_ samples: [HKSample]) async throws
    func delete(_ samples: [HKSample]) async throws
}
