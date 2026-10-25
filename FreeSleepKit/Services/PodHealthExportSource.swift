import Foundation

struct PodHealthExportSource: HealthExportSource {
    let client: PodClient
    func identity() async throws -> String {
        let identity: HealthExportRecords.Identity = try await client.get("settings")
        return identity.id
    }
    private func query(side: BedSide, range: DateInterval) -> [URLQueryItem] {
        [URLQueryItem(name: "side", value: side.rawValue), URLQueryItem(name: "startTime", value: range.start.ISO8601Format()),
         URLQueryItem(name: "endTime", value: range.end.ISO8601Format())]
    }
    func presence(side: BedSide, range: DateInterval) async throws -> [HealthExportRecords.Sleep] {
        try await client.healthExport(kind: "presence", query: query(side: side, range: range))
    }
    func heartRate(side: BedSide, range: DateInterval) async throws -> [HealthExportRecords.Vital] {
        try await client.healthExport(kind: "heart", query: query(side: side, range: range))
    }
}
