import Foundation

/// The inputs a stage model sees, one pure computation shared by training, inference and the parity fixture
/// so the contract cannot drift between them. Epochs are the challenger's 5-minute grid from bed entry.
enum StageFeatures {
    /// Which columns a model was trained on. Stored on its card as `featureContract`.
    enum Contract: String, Codable, Sendable, CaseIterable, Identifiable {
        /// The bundled challenger's four inputs, so a personal fit isolates the domain gap.
        case challenger
        /// Adds what the pod has and a wrist doesn't: HRV, breathing, 15-minute windows.
        case podNative

        var id: String { rawValue }
        var title: String {
            switch self {
            case .challenger: "Challenger parity"
            case .podNative: "Pod native"
            }
        }
        var columns: [String] {
            switch self {
            case .challenger: StageChallenger.Features.columns
            case .podNative: StageChallenger.Features.columns + StageFeatures.podNativeColumns
            }
        }

        /// The contract whose columns match a card's list exactly, if any.
        static func matching(_ columns: [String]) -> Contract? {
            allCases.first { $0.columns == columns }
        }
    }

    static let podNativeColumns = ["hrvRel", "hrv15Rel", "hr15StdRel", "br15Std", "motion15", "minutesSinceBed"]
    /// Half of the 15-minute window, so a window is centred on the epoch midpoint.
    static let windowHalf: TimeInterval = 450

    static func rows(contract: Contract, enteredBed: Date, leftBed: Date, vitals: [VitalsRecord],
                     movement: [MovementRecord]) -> [StageChallenger.FeatureEpoch] {
        let base = StageChallenger.features(enteredBed: enteredBed, leftBed: leftBed, vitals: vitals, movement: movement)
        switch contract {
        case .challenger:
            return base
        case .podNative:
            let extra = podNative(enteredBed: enteredBed, starts: base.map(\.start), vitals: vitals, movement: movement)
            return zip(base, extra).map { epoch, more in
                StageChallenger.FeatureEpoch(start: epoch.start, values: epoch.values.merging(more) { $1 })
            }
        }
    }

    /// Contract B's extra columns for each kept epoch. Ratios are to the night's median (HRV) or std (HR); a
    /// night without a positive denominator gets 0 for the ratio rather than an infinity.
    static func podNative(enteredBed: Date, starts: [Date], vitals: [VitalsRecord], movement: [MovementRecord]) -> [[String: Double]] {
        let sorted = vitals.sorted { $0.date < $1.date }
        let hrv = sorted.compactMap { record in record.hrv.flatMap { $0.isFinite ? (record.date, $0) : nil } }
        let heartRates = sorted.compactMap { record in record.heartRate.flatMap { $0.isFinite ? (record.date, $0) : nil } }
        let breathing = sorted.compactMap { record in record.breathingRate.flatMap { $0.isFinite ? (record.date, $0) : nil } }
        let nightHRVMedian = median(hrv.map(\.1))
        let nightHRStd = StageChallenger.populationStd(heartRates.map(\.1))

        func window<T>(_ samples: [(Date, T)], around mid: Date, half: TimeInterval) -> [T] {
            samples.filter { abs($0.0.timeIntervalSince(mid)) <= half }.map(\.1)
        }
        func ratio(_ value: Double, over denominator: Double) -> Double {
            denominator > 0 && denominator.isFinite ? value / denominator : 0
        }

        return starts.map { start in
            let mid = start.addingTimeInterval(StageChallenger.epochSeconds / 2)
            let epochHRV = window(hrv, around: mid, half: StageChallenger.epochSeconds / 2)
            let hrv15 = window(hrv, around: mid, half: windowHalf)
            let hr15 = window(heartRates, around: mid, half: windowHalf)
            let br15 = window(breathing, around: mid, half: windowHalf)
            let motion15 = movement.filter { abs($0.date.timeIntervalSince(mid)) <= windowHalf }.reduce(0.0) { $0 + Double($1.totalMovement) }
            return [
                "hrvRel": epochHRV.isEmpty ? 0 : ratio(StageChallenger.mean(epochHRV), over: nightHRVMedian),
                "hrv15Rel": hrv15.isEmpty ? 0 : ratio(StageChallenger.mean(hrv15), over: nightHRVMedian),
                "hr15StdRel": hr15.count < 2 ? 0 : ratio(StageChallenger.populationStd(hr15), over: nightHRStd),
                "br15Std": br15.count < 2 ? 0 : StageChallenger.populationStd(br15),
                "motion15": log(1 + motion15),
                "minutesSinceBed": start.timeIntervalSince(enteredBed) / 60
            ]
        }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
    }
}
