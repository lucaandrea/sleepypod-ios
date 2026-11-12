import Foundation

extension BedtimeRitualAttempt {
    var resultTitle: String {
        switch outcome {
        case .opening: "Opening Shortcuts"
        case .handedOff: "Waiting for Shortcuts"
        case .shortcutCompleted: "Shortcut reported completion"
        case .shortcutCancelled: "Shortcut was cancelled"
        case .shortcutFailed: "Shortcut reported a problem"
        case .notOpened: "Shortcuts did not open"
        case .unknown: "Check Endel before continuing"
        }
    }
    var resultDetail: String {
        if action == .pause { return pauseDetail }
        return switch outcome {
        case .opening, .handedOff: "Finish any steps in Shortcuts or Endel, then return here."
        case .shortcutCompleted: "Listen at the selected speakers. This return does not verify playback, volume or the timer."
        case .shortcutCancelled, .shortcutFailed: "Some steps may already have run. Check Endel and your speakers before trying again."
        case .notOpened: "Check that Shortcuts is installed and the saved name matches. Review this attempt before trying again."
        case .unknown: "No current completion could be confirmed. Audio may already be playing; this request has not been resent."
        }
    }
    private var pauseDetail: String {
        switch outcome {
        case .opening, .handedOff: "Finish the Pause Shortcut, then check that the audio stopped."
        case .shortcutCompleted: "Check that the audio stopped. This Shortcut return does not confirm it stopped."
        case .shortcutCancelled, .shortcutFailed: "Audio may still be playing. Pause directly in Endel, then check your speakers."
        case .notOpened: "The Pause Shortcut did not open. Pause directly in Endel, then check your speakers."
        case .unknown: "Stopping could not be confirmed. Pause directly in Endel; this request has not been resent."
        }
    }
    var unconfirmedObservation: String {
        action == .pause ? "Stopping the audio has not been confirmed." : "Playback has not been confirmed."
    }
    var resultSymbol: String { outcome == .shortcutCompleted ? "arrow.uturn.backward" : acceptsCallback ? "hourglass" : "info.circle" }
    func canObserve(at date: Date) -> Bool { createdAt <= date && date.timeIntervalSince(createdAt) < 12 * 3600 }
    func canRequestPause(at date: Date) -> Bool { action == .start && outcome != .notOpened && canObserve(at: date) }
}
extension BedtimeRitualAttempt.Observation {
    var displayName: String {
        switch self {
        case .heardOnSelectedSpeakers: "heard on selected speakers"
        case .notHeard: "no audio heard"
        case .stopped: "audio stopped"
        }
    }
}
