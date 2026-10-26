import Foundation
import Observation

@MainActor @Observable final class HardwareVibrationWorkspace {
    struct Playing: Sendable {
        let side: Side
        let duration: Int
        let startedAt: Date
        var end: Date { startedAt.addingTimeInterval(Double(duration)) }
        func progress(at now: Date) -> Double { min(1, max(0, now.timeIntervalSince(startedAt) / Double(duration))) }
    }
    private(set) var playing: Playing?
    private(set) var uncertainSide: Side?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var notice: String?
    private let client: any HardwareVibrationClient
    init(client: any HardwareVibrationClient) { self.client = client }
    func active(at now: Date = .now) -> Playing? { playing.flatMap { $0.end > now ? $0 : nil } }
    func play(side: Side, duration: Int, now: Date = .now) async {
        guard !busy, uncertainSide == nil else { return }
        guard active(at: now).map({ $0.side == side }) ?? true else { error = "Stop the current side's test before changing sides."; return }
        let request = HardwareVibrationRequest(side: side, duration: duration)
        do { try request.validate() } catch { self.error = error.localizedDescription; return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            guard try await client.play(request) else { error = "The controller rejected the vibration request."; return }
            playing = .init(side: side, duration: duration, startedAt: .now)
            notice = "Vibration request accepted. The timer is an estimate; vibration is not directly measured."
        } catch {
            uncertainSide = side
            self.error = "Vibration result was not confirmed. Use Stop for this side before starting another test. \(error.localizedDescription)"
        }
    }
    // Stop remains available after an uncertain command and always targets its original side.
    func stop(selectedSide: Side, now: Date = .now) async {
        guard !busy else { return }
        let side = uncertainSide ?? active(at: now)?.side ?? selectedSide
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            guard try await client.stop(side) else { uncertainSide = side; error = "The controller rejected Stop. Check the bed and try Stop again."; return }
            playing = nil; uncertainSide = nil; notice = "Stop accepted for the \(side.displayName.lowercased()) side."
        } catch {
            uncertainSide = side
            self.error = "Stop was not confirmed. Check the bed; you can retry Stop on the same side. \(error.localizedDescription)"
        }
    }
}
