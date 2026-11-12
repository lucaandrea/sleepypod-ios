import Foundation
import Observation

/// One retained session owns callbacks across navigation and a trip to Shortcuts.
@MainActor @Observable final class BedtimeRitualWorkspace {
    var presented = false
    private(set) var session: BedtimeRitualSession?
    private(set) var busy = false
    private(set) var error: String?
    private var generation = 0
    private let connect: @MainActor () async throws -> BedtimeRitualSession
    private let personalContext: @MainActor () -> Bool

    init(personalContext: @escaping @MainActor () -> Bool = { false },
         connect: @escaping @MainActor () async throws -> BedtimeRitualSession) {
        self.personalContext = personalContext; self.connect = connect
    }
    var connectionInstructions: String {
        personalContext()
            ? "Tap Done, then select your account under Personal connections on this device. Reopen Bedtime audio after reconnecting."
            : "Tap Done, then open Settings → Pod connection to connect your Pod. Reopen Bedtime audio after it connects."
    }

    func open() async {
        presented = true
        await prepare()
    }
    func prepare() async {
        checkAccount()
        guard !busy else { return }
        if let session, session.state != nil { session.expire(); return }
        busy = true; error = nil
        let operation = generation
        defer { if generation == operation { busy = false } }
        do {
            let next = try await connect()
            guard operation == generation, !Task.isCancelled, next.available else { next.invalidate(); return }
            session = next
        } catch {
            guard operation == generation else { return }
            self.error = (error as? BedtimeRitualFailure)?.errorDescription ?? "Bedtime audio could not connect to this account. Check your Pod connection, then try again."
        }
    }
    @discardableResult func receive(_ url: URL) -> Bool {
        checkAccount()
        guard session?.receive(url) == true else { return false }
        presented = true; return true
    }
    func checkAccount() {
        if let session, !session.available { withdraw() }
    }
    func withdraw() {
        generation += 1; session?.invalidate(); session = nil; busy = false
        error = BedtimeRitualFailure.accountChanged.localizedDescription
    }
}
