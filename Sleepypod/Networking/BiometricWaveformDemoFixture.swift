import Foundation

struct BiometricWaveformDemoFixture: Decodable, Sendable {
    struct Night: Decodable, Sendable { let cohortId: String; let page: InspectedRawPage }
    let parentId: String
    let request: WaveformDatasetRequest
    let pages: [Night]
    let descriptor: BiometricDataset
    let releasedByteLength: Int
    static func load() throws -> [Self] {
        guard let url = Bundle.main.url(forResource: "waveform-demo", withExtension: "json") else {
            throw WaveformInput.failure("The synthetic waveform examples are unavailable.")
        }
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }
    static func sources() throws -> [InspectedRawSource] {
        let all = try load().flatMap(\.pages).flatMap(\.page.items)
        return Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.id < $1.id }
    }
}
