import Foundation

protocol HealthExportSource: Sendable {
    func identity() async throws -> String
    func presence(side: BedSide, range: DateInterval) async throws -> [HealthExportRecords.Sleep]
    func heartRate(side: BedSide, range: DateInterval) async throws -> [HealthExportRecords.Vital]
}
