import Foundation
import Observation
import UIKit

/// Supplied by the host after checking the current controller/account. It retains no provider key.
@MainActor public struct MorningReportConnection {
    public let address: String
    let transport: any MorningReportSharingTransport
    let isCurrent: @MainActor () -> Bool
    let authorizationFailed: (@MainActor (MorningReportSharingFailure) -> Void)?
    public init(address: String, transport: any MorningReportSharingTransport, isCurrent: @escaping @MainActor () -> Bool,
                authorizationFailed: (@MainActor (MorningReportSharingFailure) -> Void)? = nil) {
        self.address = address; self.transport = transport; self.isCurrent = isCurrent
        self.authorizationFailed = authorizationFailed
    }
}

@MainActor @Observable final class MorningReportSharingWorkspace {
    static var connect: @MainActor () async throws -> MorningReportConnection = { throw MorningReportSharingFailure.unavailable }
    enum Status: Equatable { case unchecked, notShared, shared, withdrawn, uncertain }
    private(set) var status = Status.unchecked
    private(set) var message: String?
    private(set) var address: String?
    private(set) var busy = false
    private(set) var receipt: MorningReportReceipt?
    private(set) var needsUpdate = false
    private var connection: MorningReportConnection?
    private var generation = UUID()
    private var report: PersonalSleepReport?
    private let connect: @MainActor () async throws -> MorningReportConnection
    private let protectedData: @MainActor () -> Bool
    private let now: @MainActor () -> Date

    init(connect: @escaping @MainActor () async throws -> MorningReportConnection = MorningReportSharingWorkspace.connect,
         protectedData: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
         now: @escaping @MainActor () -> Date = { .now }) {
        self.connect = connect; self.protectedData = protectedData; self.now = now
    }
    var canShare: Bool { available && (status == .notShared || status == .shared && needsUpdate) }
    var canWithdraw: Bool { available && (status == .shared || status == .uncertain) }
    private var available: Bool { !busy && protectedData() && connection?.isCurrent() == true && report != nil }

    /// Only a fresh read establishes state; reopening or retrying never replays an upload.
    func refresh(_ report: PersonalSleepReport) async {
        guard !busy, protectedData() else { return }
        suspend(); let generation = generation
        self.report = report; busy = true
        defer { if self.generation == generation { busy = false } }
        do {
            let connected = try await connect()
            guard current(generation), connected.isCurrent() else { throw CancellationError() }
            connection = connected; address = connected.address
            let response = try await connected.transport.read(id: report.id)
            guard current(generation), connected.isCurrent() else { throw CancellationError() }
            try apply(response, to: report)
        } catch { finish(error, generation: generation) }
    }

    func share(consent: Bool, valid: @escaping @MainActor () -> Bool = { true }) async {
        guard consent, canShare, valid(), let connection, let report else { return }
        let generation = generation
        busy = true; message = nil
        defer { if self.generation == generation { busy = false } }
        do {
            let document = try MorningReportTransfer.document(report, now: now())
            guard current(generation), connection.isCurrent(), valid() else { throw CancellationError() }
            let response = try await connection.transport.share(id: report.id, document: document, expectedRevision: receipt?.revision)
            guard current(generation), connection.isCurrent(), valid() else { throw CancellationError() }
            try apply(response, to: report)
            message = "Shared with this Pod’s authenticated web app. No provider key or raw Health samples were included."
        } catch { finish(error, generation: generation, mutation: true) }
    }

    func withdraw(valid: @escaping @MainActor () -> Bool = { true }) async {
        guard canWithdraw, valid(), let connection, let report else { return }
        let generation = generation
        busy = true; message = nil
        defer { if self.generation == generation { busy = false } }
        do {
            guard current(generation), connection.isCurrent(), valid() else { throw CancellationError() }
            let response = try await connection.transport.withdraw(id: report.id, expectedRevision: receipt?.revision)
            guard current(generation), connection.isCurrent(), valid() else { throw CancellationError() }
            try apply(response, to: report)
            message = "The Pod’s shared copy was withdrawn. Your original report and existing backup copies are unchanged."
        } catch { finish(error, generation: generation, mutation: true) }
    }

    func suspend() {
        generation = UUID(); connection = nil; report = nil; receipt = nil
        status = .unchecked; address = nil; message = nil; needsUpdate = false; busy = false
    }
    private func current(_ token: UUID) -> Bool { generation == token && protectedData() && !Task.isCancelled }
    private func finish(_ error: Error, generation: UUID, mutation: Bool = false) {
        guard self.generation == generation else { return }
        guard protectedData(), connection?.isCurrent() != false else { suspend(); return }
        if let failure = error as? MorningReportSharingFailure, [.authentication, .forbidden].contains(failure),
           let withdrawAccess = connection?.authorizationFailed {
            withdrawAccess(failure); suspend(); return
        }
        status = mutation ? .uncertain : .unchecked
        message = error is CancellationError ? "The operation ended. Refresh sharing status before continuing."
            : (error as? MorningReportSharingFailure)?.errorDescription ?? MorningReportSharingFailure.uncertain.errorDescription
    }
    private func apply(_ response: MorningReportSharedCopy?, to report: PersonalSleepReport) throws {
        guard let response else { receipt = nil; status = .notShared; needsUpdate = false; message = nil; return }
        guard response.receipt.id == report.id else { throw MorningReportSharingFailure.invalid }
        if response.receipt.deleted {
            receipt = response.receipt; status = .withdrawn; needsUpdate = false; return
        }
        guard let saved = response.document else { throw MorningReportSharingFailure.invalid }
        let original = try MorningReportTransfer.document(report, now: now())
        let relation = try MorningReportTransfer.relationship(local: original, shared: saved)
        guard relation != .different else { throw MorningReportSharingFailure.conflict }
        receipt = response.receipt; status = .shared; needsUpdate = relation == .localHasMoreAnswers
        if relation == .sharedHasMoreAnswers { message = "The web copy has additional answers. They remain available in the web report; no answer has been replaced." }
        else { message = nil }
    }
}
