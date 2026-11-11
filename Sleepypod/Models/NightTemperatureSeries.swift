import Foundation

/// Separate paths preserve missing values, non-increasing clocks and gaps over 90 seconds.
enum NightTemperatureSeries {
    struct Point: Identifiable {
        let id: Int
        let segment: Int
        let date: Date
        let value: Double
    }
    static func points(_ samples: [NightExplanation.Thermal], target: Bool, celsius: Bool) -> [Point] {
        var result: [Point] = [], segment = 0
        var previous: Double?
        for sample in samples {
            let value = target ? (sample.powered ? sample.targetF : nil) : sample.reportedF
            guard let value else { previous = nil; segment += 1; continue }
            if let previous, sample.at <= previous || sample.at - previous > 90_000 { segment += 1 }
            result.append(.init(id: sample.id, segment: segment, date: Date(timeIntervalSince1970: sample.at / 1000),
                                value: celsius ? (value - 32) * 5 / 9 : value))
            previous = sample.at
        }
        return result
    }
}
