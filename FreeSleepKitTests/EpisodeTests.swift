import Foundation
import Testing
@testable import FreeSleepKit

struct EpisodeTests {
    @Test func sharedFixtureDecodesMainNightsShortEpisodesAndUnmodifiedReadings() throws {
        let demo = try #require(SleepDemo.shared)
        #expect(demo.analytics.nights.count == 14)
        #expect(demo.analytics.episodes?.count == 15)
        #expect(demo.ranges["7"]?.nights.count == 7)
        #expect(demo.ranges["7"]?.episodes?.count == 8)
        let night = try #require(demo.details["14"])
        #expect(night.episode.windowMinutes == 470)
        #expect(night.intervals.count == 2)
        #expect(night.samples.contains { $0.heartRate == 999 })
        #expect(night.samples.contains { $0.heartRate == nil })
        let plot = try #require(night.plots.first { $0.key == "heartRate" })
        #expect(plot.segments.count >= 3)
        #expect(plot.maximum == 61)
        #expect(plot.average == night.episode.heartRate)
        #expect(demo.details["15"]?.episode.windowMinutes == 40)
    }
    @Test func displayedClocksRespectPodTimezoneAndDistinguishRepeatedHours() throws {
        let first = try #require(EpisodeDetail.date("2026-11-01T08:30:00.000Z"))
        let second = try #require(EpisodeDetail.date("2026-11-01T09:30:00Z"))
        #expect(EpisodeDetail.clock(first, timeZone: "America/Los_Angeles", format: "MM/dd HH:mm:ss z") == "11/01 01:30:00 PDT")
        #expect(EpisodeDetail.clock(second, timeZone: "America/Los_Angeles", format: "MM/dd HH:mm:ss z") == "11/01 01:30:00 PST")
        #expect(EpisodeDetail.number(nil) == "—")
    }
    @MainActor @Test func changingSideOrRangeClearsPreviouslyDisplayedAnalytics() throws {
        let preferences = UserDefaults.standard.string(forKey: "bedSide")
        defer {
            if let preferences { UserDefaults.standard.set(preferences, forKey: "bedSide") }
            else { UserDefaults.standard.removeObject(forKey: "bedSide") }
        }
        let model = AppModel(); let analytics = try #require(SleepDemo.shared?.analytics)
        model.analytics = analytics
        model.side = model.side == .left ? .right : .left
        #expect(model.analytics == nil)
        model.analytics = analytics; model.days = 7
        #expect(model.analytics == nil)
    }
}
