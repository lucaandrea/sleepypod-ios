import Testing
import Foundation
@testable import Sleepypod

@Suite("Stage lanes and leaderboard")
@MainActor
struct StageLanesTests {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private typealias Block = StageComparison.Block

    private func block(_ fromMinute: Double, _ toMinute: Double, _ stage: SleepAnalyzer.SleepStage) -> Block {
        Block(start: t0.addingTimeInterval(fromMinute * 60), end: t0.addingTimeInterval(toMinute * 60), stage: stage)
    }

    private func night() -> StageComparison {
        // Watch: 60 min light, 60 min deep. Rules agree for the first 90 minutes, the challenger for 60.
        let watch = [block(0, 60, .light), block(60, 120, .deep)]
        let pod = [block(0, 90, .light), block(90, 120, .deep)]
        let model = StageComparison.epochStarts(enteredBed: t0, leftBed: t0.addingTimeInterval(7200)).map {
            Block(start: $0, end: $0.addingTimeInterval(300), stage: $0.timeIntervalSince(t0) < 3600 ? .deep : .light)
        }
        var comparison = StageComparison.build(enteredBed: t0, leftBed: t0.addingTimeInterval(7200), watch: watch, pod: pod, model: model, modelStatus: .ready)
        comparison.personal[.forest] = StageComparison.PersonalLane(blocks: StageComparison.gridded(watch, starts: StageComparison.epochStarts(enteredBed: t0, leftBed: t0.addingTimeInterval(7200))),
                                                                   score: StageScore.score(StageComparison.gridded(watch, starts: StageComparison.epochStarts(enteredBed: t0, leftBed: t0.addingTimeInterval(7200))), reference: watch),
                                                                   error: nil, version: "f")
        return comparison
    }

    @Test func lanesLeaveTheWatchOutAndCarryTheirScores() throws {
        let lanes = StageLanes.lanes(night(), podTitle: nil, challengerBundled: true)
        #expect(lanes.map(\.source) == [.rules, .challenger, .personal(.forest)])
        let rules = try #require(lanes.first { $0.source == .rules })
        #expect(rules.score?.epochs == 24)
        #expect(rules.matched == 18, "the rules get the first 90 minutes, 18 of 24 epochs")
        let challenger = try #require(lanes.first { $0.source == .challenger })
        #expect(challenger.matched == 0, "the challenger has every epoch backwards")
        #expect(challenger.placeholder == nil)
    }

    @Test func leaderboardRanksByKappaWithUnscoredLast() {
        let lanes = StageLanes.lanes(night(), podTitle: nil, challengerBundled: true)
            + [StageLane(source: .pod, title: "Pod forest", blocks: [], score: nil, placeholder: "none")]
        let ranked = StageLanes.ranked(lanes).map(\.source)
        #expect(ranked == [.personal(.forest), .rules, .challenger, .pod])
    }

    @Test func theAppsOwnSourceOpensFirstOtherwiseTheBest() {
        let lanes = StageLanes.lanes(night(), podTitle: nil, challengerBundled: true)
        #expect(StageLanes.initialSelection(lanes, appSource: .rules) == .personal(.forest))
        #expect(StageLanes.initialSelection(lanes, appSource: .personalForest) == .personal(.forest))
        #expect(StageLanes.initialSelection(lanes, appSource: .pod) == .personal(.forest), "a pod model not on the board falls back to the best")
        #expect(StageLanes.initialSelection([], appSource: .rules) == nil)
    }

    @Test func hourTicksLandOnWholeHoursAndStayUnderTheMaximum() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 22, minute: 50)))
        let end = start.addingTimeInterval(8.5 * 3600)
        let ticks = StageLanes.hourTicks(start: start, end: end, calendar: calendar)
        #expect(ticks.count <= 6)
        #expect(ticks.first == calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23)))
        #expect(ticks.allSatisfy { calendar.component(.minute, from: $0) == 0 })
        #expect(StageLanes.hourTicks(start: start, end: start.addingTimeInterval(60), calendar: calendar).isEmpty)
    }

    @Test func lonoDiagramScoresOneNightPerRow() {
        let rows = StageLanes.lonoRows(nights: 11)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.count == 11 && $0.filter { $0 }.count == 1 })
        #expect(rows.map { $0.firstIndex(of: true) } == [0, 5, 10])
        #expect(StageLanes.lonoRows(nights: 0).allSatisfy { $0.count == 2 })
    }

    @Test func checklistMirrorsTheEligibilityBar() {
        func card(kappa: Double, rules: Double, challenger: Double?, won: Int, nights: Int) -> StageChallenger.Card {
            StageChallenger.Card(version: "v", testVectors: [], model: "forest",
                                 metrics: .init(lono: .init(epochs: 100, kappa: kappa, accuracy: 0.5, nights: nights),
                                                rules: .init(epochs: 100, kappa: rules, accuracy: 0.4, nights: nights),
                                                challenger: challenger.map { .init(epochs: 100, kappa: $0, accuracy: 0.4, nights: nights) },
                                                nightsWon: won))
        }
        let passing = StageLanes.checklist(card(kappa: 0.3, rules: 0.1, challenger: 0.2, won: 6, nights: 10))
        #expect(passing.map(\.passed) == [true, true, true])
        #expect(passing[0].value == "0.30 vs 0.10")
        #expect(passing[2].value == "6 of 10")
        #expect(StageModelStore.isEligible(card(kappa: 0.3, rules: 0.1, challenger: 0.2, won: 6, nights: 10)))
        let failing = StageLanes.checklist(card(kappa: 0.14, rules: 0.1, challenger: nil, won: 5, nights: 10))
        #expect(failing.map(\.passed) == [false, true, false], "a missing challenger is not a blocker; a tie is not a majority")
        #expect(failing[1].value == "0.14 vs —")
        #expect(!StageModelStore.isEligible(card(kappa: 0.14, rules: 0.1, challenger: nil, won: 5, nights: 10)))
        let few = StageLanes.checklist(card(kappa: 0.5, rules: 0.1, challenger: 0.1, won: 3, nights: 4))
        #expect(few[2].passed == false, "fewer than the minimum nights never passes")
    }

    @Test func trainingReportKeepsWinsNightByNight() {
        func score(_ kappa: Double) -> StageScore { StageScore(epochs: 10, accuracy: 0.5, kappa: kappa, confusion: [], recall: []) }
        let report = StageTrainingReport(kind: .forest, contract: .podNative, nights: 3, epochs: 30, pooled: nil, rules: nil, challenger: nil,
                                         perNight: [score(0.3), score(0.1), nil], rulesPerNight: [score(0.1), score(0.2), score(0)],
                                         challengerPerNight: [nil, score(0.05), nil])
        #expect(report.wonPerNight == [true, false, false])
        #expect(report.nightsWon == 1)
    }
}
