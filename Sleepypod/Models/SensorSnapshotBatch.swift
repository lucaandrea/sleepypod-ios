import Foundation

struct SensorSnapshotBatch {
    let frames: [Data]
    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "snapshot" else { return nil }
        let latest = object["latest"] as? [[String: Any]] ?? []
        let waveform = object["waveform"] as? [[String: Any]] ?? []
        // Bound cached startup work independently of the live stream's rolling buffers.
        frames = (Array(latest.prefix(32)) + Array(waveform.suffix(40))).compactMap { try? JSONSerialization.data(withJSONObject: $0) }
    }
}
