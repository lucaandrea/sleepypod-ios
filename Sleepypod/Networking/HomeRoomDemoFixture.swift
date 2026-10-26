#if DEBUG
import Foundation

struct HomeRoomCoreFixture: Decodable, Sendable {
    let status: HomeRoomStatus
    let history: HomeRoomHistory
    let publishers: HomeRoomPublishers
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource: "room-context-core", withExtension: "json") else { throw HomeRoomStatus.issue("Synthetic room fixture is unavailable.") }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
/// UI-test-only synthetic scene. It never creates a connection or publishes a sensor report.
actor HomeRoomDemoFixtureClient: HomeRoomServing {
    private let fixture: HomeRoomCoreFixture
    private var version: HomeRoomVersion
    private let shift: Int64
    init() throws {
        let fixture = try HomeRoomCoreFixture.load(); self.fixture = fixture; version = fixture.status.version
        shift = Int64(Date.now.timeIntervalSince1970 * 1000) - fixture.status.generatedAt
    }
    func status() -> HomeRoomStatus {
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        let original = fixture.status
        let observations: [HomeRoomObservation] = version.config.mappings.map { mapping in
            let old = original.observations.first { $0.metric == mapping.metric }
            let current = version == original.version && old != nil
            return .init(metric: mapping.metric, entityId: mapping.entityId, unit: mapping.metric.unit,
                         value: current ? old?.value : nil, lastValue: current ? old?.lastValue : nil,
                         measuredAt: current ? now - 10_000 : nil, reportedAt: current ? now - 9_000 : nil,
                         receivedAt: current ? now - 8_000 : nil, expiresAt: current ? now + Int64(mapping.maxAgeSeconds * 1000) - 10_000 : nil,
                         status: current ? .fresh : version.config.enabled ? .waiting : .disabled)
        }
        return .init(apiVersion: 1, generatedAt: now, revision: version.revision, config: version.config, connected: true, topic: original.topic, observations: observations)
    }
    func configure(_ config: HomeRoomConfiguration, expectedRevision: Int64) throws -> HomeRoomVersion {
        guard expectedRevision == version.revision else { throw HomeRoomStatus.issue("Synthetic revision conflict") }
        version = .init(revision: version.revision + 1, config: try config.validated()); return version
    }
    func history(before: Int64?) -> HomeRoomHistory {
        let values = before == nil ? fixture.history.items : []
        return .init(apiVersion: 1, generatedAt: Int64(Date.now.timeIntervalSince1970 * 1000), items: values.map {
            .init(id: $0.id, revision: $0.revision, metric: $0.metric, entityId: $0.entityId, unit: $0.unit,
                  measuredAt: $0.measuredAt.map { $0 + shift }, reportedAt: $0.reportedAt + shift, receivedAt: $0.receivedAt + shift, value: $0.value, available: $0.available)
        }, nextBeforeId: nil)
    }
    func publishers() throws -> HomeRoomPublishers {
        guard version == fixture.status.version else { throw HomeRoomStatus.issue("The synthetic publisher documents describe only the original example mapping.") }
        return fixture.publishers
    }
}
#endif
