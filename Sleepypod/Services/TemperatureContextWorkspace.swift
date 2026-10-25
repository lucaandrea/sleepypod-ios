import Foundation
import Observation

@MainActor @Observable final class TemperatureContextWorkspace {
    private(set) var result: TemperatureContextResult?
    private(set) var loading = false
    private(set) var side: Side?
    private var revision = 0

    func load(side: Side, client: any TemperatureContextClient) async {
        revision += 1
        let request = revision
        if self.side != side { result = nil }
        self.side = side
        loading = true
        defer { if revision == request { loading = false } }
        let value = await client.load(side: side)
        guard revision == request, !Task.isCancelled else { return }
        result = value
    }
}
