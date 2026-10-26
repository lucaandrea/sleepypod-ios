import Foundation
import Observation

@MainActor @Observable final class TemperatureApplicationWorkspace {
    private(set) var items: [TemperatureApplication] = []
    private(set) var generatedAt: Date?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var nextBeforeId: Int?
    private var generation = UUID()
    private var scope: [String]?
    private var side: Side?
    private var client: (any TemperatureApplicationClient)?
    private let makeClient: () throws -> any TemperatureApplicationClient
    private let owner: () -> [String]
    init(client: @escaping () throws -> any TemperatureApplicationClient,
         owner: @escaping () -> [String] = { OwnerConnection.revision }) { makeClient = client; self.owner = owner }
    func invalidate() {
        generation = UUID(); items = []; generatedAt = nil; error = nil; loading = false
        nextBeforeId = nil; scope = nil; side = nil; client = nil
    }
    /// Freeze the controller and side before loading; obsolete replies cannot replace the current page.
    func reload(side: Side) async {
        invalidate(); loading = true
        let request = generation, scope = owner()
        defer { if generation == request { loading = false } }
        do {
            try check(request, scope)
            let client = try makeClient(); try await client.available(); try check(request, scope)
            let page = try await client.read(side: side, before: nil); try check(request, scope)
            try page.validate(side: side)
            self.scope = scope; self.side = side; self.client = client
            items = page.items; generatedAt = Date(timeIntervalSince1970: page.generatedAt / 1000); nextBeforeId = page.nextBeforeId
        } catch {
            guard generation == request else { return }
            if owner() != scope { invalidate() }
            else if !Task.isCancelled { self.error = APIError.message(for: error) }
        }
    }
    /// Append only validated, disjoint older records. A failed page leaves the prior page available.
    func more() async {
        guard !loading, let before = nextBeforeId, let side, let scope, let client else { return }
        let request = generation; loading = true; error = nil
        defer { if generation == request { loading = false } }
        do {
            try check(request, scope)
            let page = try await client.read(side: side, before: before); try check(request, scope)
            try page.validate(side: side, before: before)
            guard items.count + page.items.count <= 10_000,
                  Set(items.map(\.id)).isDisjoint(with: page.items.map(\.id)),
                  Set(items.map(\.attemptId)).isDisjoint(with: page.items.map(\.attemptId)) else { throw TemperatureApplicationPage.invalid }
            items += page.items; nextBeforeId = page.nextBeforeId
        } catch {
            guard generation == request else { return }
            if owner() != scope { invalidate() }
            else if !Task.isCancelled { self.error = APIError.message(for: error) }
        }
    }
    private func check(_ request: UUID, _ scope: [String]) throws {
        try Task.checkCancellation()
        guard generation == request, owner() == scope else { throw NativeControlFailure.changedOwner }
    }
}
