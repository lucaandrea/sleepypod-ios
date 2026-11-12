import Foundation

enum BedtimeRitualFailure: Error, LocalizedError, Equatable {
    case invalid, accountChanged, setupRequired, quietUnavailable, someoneResting, pending, storage, expired, foregroundRequired
    var errorDescription: String? {
        switch self {
        case .invalid: "This bedtime setup could not be verified. Review it before continuing."
        case .accountChanged: "Your account changed. Open bedtime audio from your current account."
        case .setupRequired: "First check that your saved Shortcuts use the mode, speakers, volume and timer shown here."
        case .quietUnavailable: "Shared quiet status is unavailable. Reconnect before starting bedroom audio."
        case .someoneResting: "Someone has requested quiet time. Bedroom audio has not been started."
        case .pending: "Check the previous handoff before starting another. Audio may already be playing."
        case .storage: "Secure audio history is unavailable. Check Endel before trying another handoff."
        case .expired: "This handoff expired. Check the audio before reviewing a new request."
        case .foregroundRequired: "Open bedtime audio on this device to continue."
        }
    }
}

/// Desired settings belong to one reviewed, user-configured Shortcut pair.
/// Changing any setting creates a new revision and requires another setup review.
struct BedtimeRitualPlan: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case sleep, relax }
    let revision: UUID
    let mode: Mode
    let startShortcut: String
    let pauseShortcut: String
    let speakerName: String
    let volumePercent: Int
    let durationMinutes: Int

    func validate() throws {
        guard [startShortcut, pauseShortcut, speakerName].allSatisfy(Self.validName),
              startShortcut != pauseShortcut, (0...100).contains(volumePercent),
              (1...720).contains(durationMinutes) else { throw BedtimeRitualFailure.invalid }
    }
    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 240 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

struct BedtimeRitualSetup: Codable, Equatable, Sendable {
    let plan: BedtimeRitualPlan
    let reviewedAt: Date
    func validate(now: Date) throws {
        try plan.validate()
        guard BedtimeRitualClock.valid(reviewedAt), reviewedAt <= now else { throw BedtimeRitualFailure.setupRequired }
    }
}

enum BedtimeRitualClock {
    static let callbackLifetime: TimeInterval = 120
    static func valid(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && (0...253_402_300_799).contains(date.timeIntervalSince1970) }
    static func scope(_ value: String) -> Bool { (16...256).contains(value.utf8.count) && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
}

/// A fresh Pod read is required to start. It never identifies which sleeper is resting.
struct BedtimeRitualQuiet: Equatable, Sendable {
    let scope: String
    let generatedAt: Date
    let expiresAt: Date
    let paused: Bool
    let until: Date?
    func validate(scope expected: String, now: Date) throws {
        guard scope == expected else { throw BedtimeRitualFailure.accountChanged }
        guard BedtimeRitualClock.valid(generatedAt), BedtimeRitualClock.valid(expiresAt),
              generatedAt <= now.addingTimeInterval(5), now < expiresAt,
              expiresAt > generatedAt, expiresAt.timeIntervalSince(generatedAt) <= 15,
              paused == (until != nil), until.map({ BedtimeRitualClock.valid($0) && $0 > now }) ?? true
        else { throw BedtimeRitualFailure.quietUnavailable }
        if paused { throw BedtimeRitualFailure.someoneResting }
    }
}

struct BedtimeRitualAttempt: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case start, pause }
    enum Outcome: String, Codable, Sendable {
        case opening, handedOff, shortcutCompleted, shortcutCancelled, shortcutFailed, notOpened, unknown
    }
    enum Observation: String, Codable, Sendable { case heardOnSelectedSpeakers, notHeard, stopped }
    struct Playback: Codable, Equatable, Sendable { let observation: Observation; let observedAt: Date }
    let requestId: UUID
    let nonce: UUID
    let action: Action
    let plan: BedtimeRitualPlan
    let createdAt: Date
    let expiresAt: Date
    var outcome: Outcome
    var outcomeAt: Date?
    var playback: Playback?
    var acknowledgedAt: Date?

    var acceptsCallback: Bool { outcome == .opening || outcome == .handedOff }
    var needsReview: Bool { acknowledgedAt == nil }

    func validate() throws {
        try plan.validate()
        guard BedtimeRitualClock.valid(createdAt), BedtimeRitualClock.valid(expiresAt),
              expiresAt.timeIntervalSince(createdAt) == BedtimeRitualClock.callbackLifetime,
              acceptsCallback == (outcomeAt == nil),
              outcomeAt.map({ BedtimeRitualClock.valid($0) && $0 >= createdAt }) ?? true,
              acknowledgedAt.map({ BedtimeRitualClock.valid($0) && $0 >= createdAt && !acceptsCallback }) ?? true
        else { throw BedtimeRitualFailure.invalid }
        if let playback {
            guard BedtimeRitualClock.valid(playback.observedAt), playback.observedAt >= createdAt,
                  action == .start || playback.observation == .stopped else { throw BedtimeRitualFailure.invalid }
        }
    }
}

struct BedtimeRitualSavedState: Codable, Equatable, Sendable {
    let version: Int
    let scope: String
    var setup: BedtimeRitualSetup?
    var attempt: BedtimeRitualAttempt?
    func validate(scope expected: String) throws {
        guard version == 1, scope == expected, BedtimeRitualClock.scope(scope) else { throw BedtimeRitualFailure.invalid }
        if let setup {
            try setup.plan.validate()
            guard BedtimeRitualClock.valid(setup.reviewedAt) else { throw BedtimeRitualFailure.invalid }
        }
        try attempt?.validate()
        if let attempt, setup?.plan != attempt.plan { throw BedtimeRitualFailure.invalid }
    }
}
