import Foundation

struct CalibrationSignalBuffer: Sendable {
    struct Piezo: Sendable { let time: Date; let samples: [Double] }
    struct Capacitance: Sendable { let time: Date; let values: [Double] }
    struct Temperature: Sendable { let time: Date; let zones: [Double?] }
    struct Envelope: Sendable { let time: Date; let low: Double; let high: Double }
    private(set) var piezo: [Side: [Piezo]] = [:]
    private(set) var capacitance: [Side: [Capacitance]] = [:]
    private(set) var temperature: [Side: [Temperature]] = [:]

    // Store bounded, arrival-stamped windows independently so slow temperature frames survive piezo traffic.
    mutating func append(_ frame: SensorFrame, at time: Date = .now) {
        for side in Side.allCases {
            switch frame {
            case .piezoDual(let frame):
                let samples = (side == .left ? frame.left1 : frame.right1).map(Double.init)
                if !samples.isEmpty { piezo[side, default: []].append(.init(time: time, samples: samples)) }
                piezo[side] = Array((piezo[side] ?? []).filter { time.timeIntervalSince($0.time) <= 30 }.suffix(60))
            case .capSense2(let frame), .capSense(let frame):
                let values = (side == .left ? frame.left : frame.right).values.map(Double.init)
                capacitance[side, default: []].append(.init(time: time, values: values))
                capacitance[side] = Array((capacitance[side] ?? []).filter { time.timeIntervalSince($0.time) <= 30 }.suffix(180))
            case .bedTemp2(let frame), .bedTemp(let frame):
                let values = (side == .left ? frame.left : frame.right).temps
                let zones: [Double?] = (0..<3).map { index in
                    guard values.indices.contains(index), values[index].isFinite, values[index] > -100 else { return nil }
                    return Double(values[index])
                }
                temperature[side, default: []].append(.init(time: time, zones: zones))
                temperature[side] = Array((temperature[side] ?? []).filter { time.timeIntervalSince($0.time) <= 600 }.suffix(100))
            default: break
            }
        }
    }
    static func range(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), let low = samples.min(), let high = samples.max() else { return nil }
        return high - low
    }
    static func envelope(_ frames: [Piezo], buckets: Int = 8) -> [Envelope] {
        frames.flatMap { frame -> [Envelope] in
            guard !frame.samples.isEmpty, frame.samples.allSatisfy(\.isFinite), buckets > 0 else { return [] }
            let mean = frame.samples.reduce(0, +) / Double(frame.samples.count)
            let perBucket = max(1, Int(ceil(Double(frame.samples.count) / Double(buckets))))
            return stride(from: 0, to: frame.samples.count, by: perBucket).compactMap { index in
                let values = frame.samples[index..<min(frame.samples.count, index + perBucket)]
                guard let low = values.min(), let high = values.max() else { return nil }
                let offset = -1 + (Double(index) + Double(perBucket) / 2) / Double(frame.samples.count)
                return Envelope(time: frame.time.addingTimeInterval(min(0, offset)), low: low - mean, high: high - mean)
            }
        }
    }
}
