import Foundation

struct SensorWaveformReplay {
    struct Range: Decodable, Sendable { let min: Double; let max: Double }
    struct Response: Decodable { let type: String; let requestId: Int; let frames: [PiezoDualFrame] }
    private(set) var range: Range?
    private(set) var frames: [PiezoDualFrame]?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var requestID = 0
    private(set) var requestedTime: Double?
    mutating func setRange(_ value: Range?) {
        range = value.flatMap { $0.min.isFinite && $0.max.isFinite && $0.min > 0 && $0.max > $0.min ? $0 : nil }
    }
    mutating func begin(at timestamp: Double) -> Int? {
        guard let range, timestamp.isFinite, (range.min...range.max).contains(timestamp) else { return nil }
        requestID += 1; frames = []; loading = true; error = nil; requestedTime = timestamp
        return requestID
    }
    mutating func accept(_ response: Response) {
        guard response.type == "waveform", response.requestId == requestID, loading else { return }
        frames = Array(response.frames.filter { $0.freq > 0 && $0.freq <= 4000 }.sorted { $0.ts < $1.ts }.suffix(40))
        loading = false
    }
    mutating func fail(_ message: String, request: Int) {
        guard request == requestID, loading else { return }
        error = message; loading = false
    }
    mutating func goLive() { requestID += 1; frames = nil; loading = false; error = nil; requestedTime = nil }
}

struct SensorWaveformSample: Identifiable {
    let time: Double
    let value: Double
    let side: Side
    let segment: Int
    var id: String { "\(side.rawValue)-\(time)" }
    var run: String { "\(side.rawValue)-\(segment)" }
    // Anchor replay samples to firmware time, preserving missing frames and sample-rate changes.
    static func points(frames: [PiezoDualFrame], sides: [Side]) -> [Self] {
        sides.flatMap { side in
            var result: [Self] = [], segment = 0
            var previousEnd: Double?
            var previousRate: Int?
            for frame in frames.sorted(by: { $0.ts < $1.ts }) {
                guard frame.freq > 0, frame.freq <= 4000 else { continue }
                let samples = side == .left ? frame.left1 : frame.right1
                let start = Double(frame.ts), rate = Double(frame.freq)
                if previousRate != frame.freq || previousEnd.map({ abs(start - $0) > 1 / rate }) == true { segment += 1 }
                // A min/max envelope retains brief movement peaks while bounding chart work.
                let width = max(1, Int(ceil(Double(samples.count) / 60)))
                for offset in stride(from: 0, to: samples.count, by: width) {
                    let end = min(samples.count, offset + width)
                    let indices = offset..<end
                    let low = indices.min { samples[$0] < samples[$1] }
                    let high = indices.max { samples[$0] < samples[$1] }
                    for index in Set([low, high].compactMap { $0 }).sorted() {
                        result.append(.init(time: start + Double(index) / rate, value: Double(samples[index]), side: side, segment: segment))
                    }
                }
                previousEnd = start + Double(samples.count) / rate; previousRate = frame.freq
            }
            return result
        }
    }
}
