import Foundation

struct SensorStreamActivity: Sendable {
    struct Group: Sendable, Identifiable { let id: String; let title: String; let types: [String] }
    struct Tick: Sendable { let type: String; let time: Date }
    static let groups: [Group] = [
        .init(id: "status", title: "Device", types: ["deviceStatus"]),
        .init(id: "piezo", title: "Piezo", types: ["piezo-dual", "lps"]),
        .init(id: "presence", title: "Presence", types: ["capSense2", "capSense"]),
        .init(id: "bedTemp", title: "Bed temperature", types: ["bedTemp2", "bedTemp"]),
        .init(id: "freezer", title: "Freezer", types: ["frzHealth", "frzTemp", "frzTherm"]),
        .init(id: "log", title: "Log", types: ["log", "gesture"])
    ]
    private(set) var ticks: [Tick] = []
    private(set) var last: [String: Tick] = [:]
    // Count recognized envelopes even when their payload cannot be decoded into typed readings.
    mutating func append(data: Data, at now: Date = .now) {
        struct Envelope: Decodable { let type: String }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        append(type: envelope.type, at: now)
    }
    // Keep a bounded minute of arrivals separately from the larger raw JSON payloads.
    mutating func append(type: String, at now: Date = .now) {
        guard let group = Self.groups.first(where: { $0.types.contains(type) }) else { return }
        let tick = Tick(type: type, time: now)
        last[group.id] = tick
        ticks = Array(ticks.filter { now.timeIntervalSince($0.time) <= 60 }.suffix(1199))
        ticks.append(tick)
    }
    func recent(_ group: Group, at now: Date) -> [Tick] { ticks.filter { group.types.contains($0.type) && (0...60).contains(now.timeIntervalSince($0.time)) } }
}
