import Testing
import Foundation
import HealthKit
@testable import Sleepypod

@Suite("Stage model comparison")
@MainActor
struct StageComparisonTests {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private typealias Block = StageComparison.Block

    private func block(_ fromMinute: Double, _ toMinute: Double, _ stage: SleepAnalyzer.SleepStage) -> Block {
        Block(start: t0.addingTimeInterval(fromMinute * 60), end: t0.addingTimeInterval(toMinute * 60), stage: stage)
    }

    // MARK: Kappa port

    /// Hand-checked: reference W W L L L L D D R R, predicted W L L L D L D L R W.
    /// 6 of 10 match; marginals predicted (W2 L5 D2 R1), reference (W2 L4 D2 R2); chance = (4 + 20 + 4 + 2) / 100 = 0.30;
    /// kappa = (0.6 − 0.3) / 0.7 = 3/7. An eleventh epoch outside the reference is not counted.
    @Test func scoreMatchesTheCoreRuleOnAHandCheckedNight() throws {
        let reference: [SleepAnalyzer.SleepStage] = [.wake, .wake, .light, .light, .light, .light, .deep, .deep, .rem, .rem]
        let predicted: [SleepAnalyzer.SleepStage] = [.wake, .light, .light, .light, .deep, .light, .deep, .light, .rem, .wake, .deep]
        let ref = reference.enumerated().map { block(Double($0) * 5, Double($0 + 1) * 5, $1) }
        let epochs = predicted.enumerated().map { block(Double($0) * 5, Double($0 + 1) * 5, $1) }
        let score = try #require(StageScore.score(epochs, reference: ref))
        #expect(score.epochs == 10)
        #expect(score.accuracy == 0.6)
        #expect(abs(try #require(score.kappa) - 3.0 / 7.0) < 1e-12)
        // Rows are the reference, columns the prediction, both wake / light / deep / rem.
        #expect(score.confusion == [[1, 1, 0, 0], [0, 3, 1, 0], [0, 1, 1, 0], [1, 0, 0, 1]])
        #expect(score.recall == [0.5, 0.75, 0.5, 0.5])
    }

    @Test func scoreIsNilWithoutOverlapAndKappaNilAtTotalChance() throws {
        #expect(StageScore.score([block(0, 5, .light)], reference: [block(10, 20, .light)]) == nil)
        let allWake = try #require(StageScore.score([block(0, 5, .wake), block(5, 10, .wake)], reference: [block(0, 10, .wake)]))
        #expect(allWake.accuracy == 1)
        #expect(allWake.kappa == nil)
    }

    @Test func midpointOnABoundaryTakesTheLaterBlock() throws {
        // Epoch 0–10 min has its midpoint at 5 min, the start of the second reference block.
        let score = try #require(StageScore.score([block(0, 10, .deep)], reference: [block(0, 5, .light), block(5, 10, .deep)]))
        #expect(score.accuracy == 1)
    }

    // MARK: Comparison

    @Test func podBlocksAreScoredOnTheFiveMinuteGrid() throws {
        // 32 minutes in bed: six whole epochs. The pod switches at 12 min, the Watch at 10 min.
        let pod = [block(0, 12, .light), block(12, 32, .deep)]
        let watch = [block(-20, 10, .light), block(10, 40, .deep)]
        let model = [block(0, 5, .light), block(5, 10, .rem), block(20, 25, .deep)]
        let comparison = StageComparison.build(enteredBed: t0, leftBed: t0.addingTimeInterval(32 * 60), watch: watch, pod: pod,
                                               model: model, modelStatus: .ready)
        #expect(comparison.epochs == 6)
        // Grid midpoints 2.5, 7.5, 12.5, … : the pod reads light, light, deep, deep, deep, deep; the Watch light, light, deep ×4.
        let podScore = try #require(comparison.podScore)
        #expect(podScore.epochs == 6 && podScore.accuracy == 1)
        let modelScore = try #require(comparison.modelScore)
        #expect(modelScore.epochs == 3)
        #expect(abs(modelScore.accuracy - 2.0 / 3.0) < 1e-12)
        // The axis widens to the Watch's night.
        #expect(comparison.start == t0.addingTimeInterval(-20 * 60))
        #expect(comparison.end == t0.addingTimeInterval(40 * 60))
    }

    // MARK: Watch source

    private let app = "com.jonathanng.com.ios.sleepypod"

    private func source(_ bundle: String, product: String?, model: String?, name: String? = "Apple Watch") -> StageComparison.HealthSource {
        .init(bundleIdentifier: bundle, productType: product, deviceModel: model, deviceName: name)
    }

    @Test func onlyAppleWatchSamplesCount() {
        let watchBundle = "com.apple.health.81A1C9E2-6AB2-4D2B-9A6E-3C2F0D7B5E11"
        #expect(StageComparison.isAppleWatchSleep(source(watchBundle, product: "Watch7,1", model: "Watch"), appBundleID: app))
        #expect(StageComparison.isAppleWatchSleep(source(watchBundle, product: nil, model: "Apple Watch"), appBundleID: app))
        // iPhone in-bed samples come from Apple Health too, but not from a Watch.
        #expect(!StageComparison.isAppleWatchSleep(source(watchBundle, product: "iPhone17,1", model: "iPhone", name: "iPhone"), appBundleID: app))
        // sleepypod's own writes, even if they carried Watch hardware, and anything on its "sleepypod" device.
        #expect(!StageComparison.isAppleWatchSleep(source(app, product: "Watch7,1", model: "Watch"), appBundleID: app))
        #expect(!StageComparison.isAppleWatchSleep(source(app + ".widget", product: "Watch7,1", model: "Watch"), appBundleID: app))
        #expect(!StageComparison.isAppleWatchSleep(source(watchBundle, product: "Watch7,1", model: "Pod", name: "sleepypod"), appBundleID: app))
        // Third-party sleep apps that write with Watch hardware are not Apple's staging.
        #expect(!StageComparison.isAppleWatchSleep(source("com.tantsissa.AutoSleep", product: "Watch7,1", model: "Watch"), appBundleID: app))
    }

    @Test func samplesWrittenByThisAppNeverCountAsTheWatch() {
        // A sample created here is sourced from the test host, sleepypod itself, whatever device it names.
        let device = HKDevice(name: "Apple Watch", manufacturer: "Apple Inc.", model: "Watch", hardwareVersion: "Watch7,1",
                              firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
        let sample = HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                      start: t0, end: t0.addingTimeInterval(600), device: device, metadata: nil)
        #expect(!StageComparison.isAppleWatchSleep(StageComparison.HealthSource(sample)))
    }

    @Test func watchValuesMapAndInBedIsIgnored() {
        let watch = source("com.apple.health.A", product: "Watch7,1", model: "Watch")
        let values: [(HKCategoryValueSleepAnalysis, SleepAnalyzer.SleepStage?)] = [
            (.asleepCore, .light), (.asleepDeep, .deep), (.asleepREM, .rem), (.awake, .wake), (.inBed, nil), (.asleepUnspecified, nil)
        ]
        let samples = values.enumerated().map { index, pair in
            (source: watch, value: pair.0.rawValue, start: t0.addingTimeInterval(Double(index) * 60), end: t0.addingTimeInterval(Double(index + 1) * 60))
        }
        let stages = StageComparison.watchStages(samples, appBundleID: app)
        #expect(stages.map(\.stage) == values.compactMap(\.1))
    }

    @Test func watchNightIsTheSessionOverlappingTheBed() {
        let nap = [block(-600, -560, .light)]
        let night = [block(-10, 60, .light), block(60, 200, .deep)]
        #expect(StageComparison.watchNight(nap + night, enteredBed: t0, leftBed: t0.addingTimeInterval(8 * 3600)) == night)
        #expect(StageComparison.watchNight(nap, enteredBed: t0, leftBed: t0.addingTimeInterval(8 * 3600)).isEmpty)
    }

    // MARK: Export

    private func collectKeys(_ value: Any, into keys: inout Set<String>, strings: inout [String]) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                keys.insert(key)
                collectKeys(child, into: &keys, strings: &strings)
            }
        } else if let array = value as? [Any] {
            array.forEach { collectKeys($0, into: &keys, strings: &strings) }
        } else if let string = value as? String {
            strings.append(string)
        }
    }

    @Test func exportIsDeIdentified() throws {
        let enteredBed = t0, leftBed = t0.addingTimeInterval(40 * 60)
        let scored = StageComparison.build(enteredBed: enteredBed, leftBed: leftBed, watch: [block(0, 40, .light)],
                                           pod: [block(0, 40, .deep)], model: [block(0, 5, .light), block(5, 10, .wake)], modelStatus: .ready)
        let noWatch = StageComparison.build(enteredBed: enteredBed.addingTimeInterval(86400), leftBed: leftBed.addingTimeInterval(86400),
                                            watch: [], pod: [block(0, 40, .deep)], model: [], modelStatus: .notBundled)
        let unbundled = StageComparison.build(enteredBed: enteredBed, leftBed: leftBed, watch: [block(0, 40, .light)],
                                              pod: [block(0, 40, .light)], model: [], modelStatus: .notBundled)
        let export = StageAgreementExport(nights: [scored, noWatch, unbundled], modelVersion: "1.0.0")
        let data = try export.data()
        let text = try #require(String(data: data, encoding: .utf8))
        let json = try JSONSerialization.jsonObject(with: data)

        var keys = Set<String>(), strings: [String] = []
        collectKeys(json, into: &keys, strings: &strings)
        #expect(keys.isSubset(of: ["schema", "modelVersion", "epochSeconds", "stageOrder", "nights",
                                   "night", "epochs", "podRules", "model", "kappa", "accuracy", "confusion"]))
        #expect(Set(strings).isSubset(of: ["stage-challenger-v1", "1.0.0", "wake", "light", "deep", "rem"]))
        // No timestamps in any form: unix seconds, milliseconds, or a formatted date.
        for stamp in [enteredBed, leftBed] {
            #expect(!text.contains(String(Int(stamp.timeIntervalSince1970))))
            #expect(!text.contains(String(Int(stamp.timeIntervalSince1970 * 1000))))
            #expect(!text.contains(stamp.formatted(.iso8601.year())))
        }
        #expect(!text.contains("heartRate") && !text.contains("movement") && !text.contains("hr"))

        // Only Watch-scored nights, renumbered from 0; a lane that could not be scored is null.
        let root = try #require(json as? [String: Any])
        #expect(root["schema"] as? String == "stage-challenger-v1")
        let nights = try #require(root["nights"] as? [[String: Any]])
        #expect(nights.map { $0["night"] as? Int } == [0, 1])
        #expect(nights[1]["model"] is NSNull)
        let podRules = try #require(nights[0]["podRules"] as? [String: Any])
        #expect(podRules["epochs"] as? Int == 8)
        #expect(podRules["accuracy"] as? Double == 0)
        #expect((podRules["confusion"] as? [[Int]])?[1] == [0, 0, 8, 0])
        #expect(nights[0]["epochs"] as? Int == 8)
    }
}
