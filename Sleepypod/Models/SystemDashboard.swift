import Foundation

struct SystemRuntimeFacts: Decodable, Sendable {
    struct Memory: Decodable, Sendable {
        let heapTotalBytes: Double
        let heapUsedBytes: Double
        let externalBytes: Double
        let arrayBuffersBytes: Double
    }
    struct Startup: Decodable, Sendable, Identifiable {
        let name: String
        let elapsedMs: Double
        let durationMs: Double
        var id: String { name }
    }
    struct EventLoop: Decodable, Sendable { let meanMs: Double; let p95Ms: Double; let maxMs: Double }
    let uptimeSeconds: Double
    let rssBytes: Double
    let memory: Memory?
    let startup: [Startup]
    let sensorSource: String
    let firstFrameMs: Double?
    let eventLoop: EventLoop
    var uptime: String {
        guard uptimeSeconds.isFinite, uptimeSeconds >= 0, uptimeSeconds < Double(Int.max) else { return "Unknown" }
        let minutes = Int(uptimeSeconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
    }
}

struct SystemMaintenanceFacts: Decodable, Sendable {
    let pumpStallProtectionEnabled: Bool
    let reportsPumpSpeed: Bool?
    let primePodDaily: Bool
    let primePodTime: String?
    let lastPrimeAt: Double?
    let firstPrimeRecordedAt: Double?
    var needsPumpProtection: Bool { !pumpStallProtectionEnabled && reportsPumpSpeed != false }
    func needsPrime(at now: Date) -> Bool {
        guard !primePodDaily else { return false }
        guard let lastPrimeAt else { return true }
        return now.timeIntervalSince1970 * 1000 - lastPrimeAt > 7 * 86400 * 1000
    }
}

struct DashboardNight: Sendable {
    let timeline: SystemSchedulerTimeline
    let start: Date
    let end: Date
    var range: ClosedRange<Date> { start...end }
    var events: [SystemSchedulerTimeline.Occurrence] {
        timeline.occurrences.filter { range.contains($0.date) }.sorted { $0.at < $1.at }
    }
    var podEvents: [SystemSchedulerTimeline.Occurrence] {
        events.filter { !["temperature", "power_on", "power_off"].contains($0.type) }
    }
    func nextTemperature(sides: [Side]) -> SystemSchedulerTimeline.Occurrence? {
        timeline.upcoming.first { $0.type == "temperature" && $0.targetTempF != nil && $0.side.map(sides.contains) == true }
    }
    func target(side: Side, at time: Date) -> Double? {
        SystemSchedulerTimeline.heldTarget(timeline.occurrences, side: side, at: time)
    }
    func spans(side: Side) -> [SystemSchedulerTimeline.TargetSpan] {
        SystemSchedulerTimeline.targetSpans(.init(start: start, end: end, occurrences: timeline.occurrences), side: side, range: range)
    }
    // Tonight changes at 9 AM in the Pod's timezone; calendar dates retain DST changes.
    init?(timeline: SystemSchedulerTimeline) {
        let calendar = timeline.calendar
        let dayOffset = calendar.component(.hour, from: timeline.date) < 9 ? -1 : 0
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: timeline.date),
              let start = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
              let end = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: nextDay) else { return nil }
        self.timeline = timeline; self.start = start; self.end = end
    }
}
