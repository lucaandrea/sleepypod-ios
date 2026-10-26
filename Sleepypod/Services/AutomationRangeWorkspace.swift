import Foundation
import Observation

@MainActor @Observable
final class AutomationRangeWorkspace {
    var nights = 5
    private(set) var result: AutomationReplaySummary?
    private(set) var running = false
    private(set) var error: String?
    private var replayed: AutomationDefinition?
    private var replayedNights: Int?
    private let client: any AutomationClient
    init(client: any AutomationClient) { self.client = client }
    func isCurrent(_ definition: AutomationDefinition) -> Bool { replayed == definition && replayedNights == nights }
    func run(_ definition: AutomationDefinition) async {
        guard !running, definition.validation == nil, (1...14).contains(nights) else { return }
        let requestedNights = nights
        running = true; error = nil; result = nil; replayed = nil; replayedNights = nil
        defer { running = false }
        do {
            let response = try await client.range(definition, nights: requestedNights)
            guard !Task.isCancelled, nights == requestedNights else { return }
            result = response; replayed = definition; replayedNights = requestedNights
        } catch { guard !Task.isCancelled else { return }; self.error = error.localizedDescription }
    }
}
