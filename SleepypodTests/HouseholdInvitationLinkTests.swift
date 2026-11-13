import XCTest
import FreeSleepKit
@testable import Sleepypod

@MainActor final class HouseholdInvitationLinkTests: XCTestCase {
    private let code = String(repeating: "A", count: 43)
    private var text: String { "https://bed.example.com/household/index.html#invite=" + code }
    func testBrowserInvitationParsesOriginAndSecretWithoutQuery() throws {
        let link = try HouseholdInvitationLink("\n " + text + " \n")
        XCTAssertEqual(link.endpoint.absoluteString, "https://bed.example.com")
        XCTAssertEqual(link.invitation, code); XCTAssertNil(link.endpoint.fragment); XCTAssertNil(link.endpoint.query)
    }
    func testShareLinkRoundTripsBrowserFormatIncludingLANPort() throws {
        for address in ["https://bed.example.com", "http://10.0.1.69:3000", "https://bed.example.com:8443"] {
            let endpoint = try HouseholdHTTPClient.endpoint(address)
            let url = try XCTUnwrap(HouseholdInvitationLink.url(endpoint: endpoint, invitation: code))
            let link = try HouseholdInvitationLink(url.absoluteString)
            XCTAssertEqual(link.endpoint, endpoint); XCTAssertEqual(link.invitation, code)
            XCTAssertNil(url.query); XCTAssertEqual(url.fragment, "invite=" + code)
        }
    }
    func testRejectsAmbiguousOrCredentialBearingLinksAndOwnerKeyURLs() {
        let invalid = [
            "https://name:password@bed.example.com/household/index.html#invite=" + code,
            "https://bed.example.com/household/index.html?invite=" + code,
            text + "&invite=" + code, text + "&ownerKey=secret", text + "#extra",
            "https://bed.example.com/household/index.html#invite=short",
            "https://bed.example.com/household/index.html#ownerKey=" + code,
            text.replacingOccurrences(of: "/household/index.html", with: "/en/settings"),
            text.replacingOccurrences(of: "https:", with: "file:"),
            text.replacingOccurrences(of: "/household/index.html", with: "/household/%69ndex.html"),
            text.replacingOccurrences(of: "invite=", with: "invite=%41"),
            text.replacingOccurrences(of: "bed.example.com", with: "bed .example.com"),
            text + String(repeating: "A", count: 2048)
        ]
        for value in invalid { XCTAssertThrowsError(try HouseholdInvitationLink(value), value.components(separatedBy: "#")[0]) }
    }
    func testInvalidSecretCannotBecomeShareLink() {
        XCTAssertNil(HouseholdInvitationLink.url(endpoint: URL(string: "https://bed.example.com")!, invitation: "owner key"))
    }
    func testEditingAndClearingInvalidateReviewWithoutPersistingAnything() throws {
        var draft = HouseholdInvitationDraft(); draft.edit(text); XCTAssertNil(draft.reviewed)
        draft.review(); XCTAssertEqual(try XCTUnwrap(draft.reviewed).invitation, code)
        draft.edit(text + "&anything=else"); XCTAssertNil(draft.reviewed); draft.review(); XCTAssertNotNil(draft.error)
        XCTAssertFalse(draft.error!.contains(code)); draft.clear(); XCTAssertTrue(draft.text.isEmpty); XCTAssertNil(draft.reviewed); XCTAssertNil(draft.error)
    }
    func testJoinUsesReviewedOriginAndSecretWithoutReadingOwnerKey() async throws {
        let link = try HouseholdInvitationLink(text), server = InvitationTestTransport(), vault = InvitationTestVault()
        let defaults = UserDefaults(suiteName: "invitation-test-\(UUID().uuidString)")!
        defaults.set(true, forKey: PersonalWorkspaceBoundary.preferenceKey)
        let model = HouseholdWorkspace(vault: vault, defaults: defaults, client: { endpoint in
            XCTAssertEqual(endpoint, link.endpoint); return server
        }, capability: { false }, ownerEndpoint: { nil }, ownerKey: { _ in XCTFail("Personal invitation must not read owner key"); return "" })
        let before = await server.count; XCTAssertEqual(before, 0)
        await model.start(address: link.endpoint.absoluteString, name: "Example sleeper", deviceName: "Example phone", invitation: link.invitation)
        let requests = await server.requests; XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first); XCTAssertEqual(request.path, "household/join"); XCTAssertEqual(request.method, "POST"); XCTAssertNil(request.token)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(body["invitation"], code); XCTAssertTrue(HouseholdValidation.secret(try XCTUnwrap(body["deviceSecret"])))
        XCTAssertEqual(model.error, HouseholdFailure.invitation.localizedDescription)
    }
}
private actor InvitationTestTransport: HouseholdTransport {
    struct Request: Sendable { let path: String; let method: String; let token: String?; let body: Data? }
    var requests: [Request] = []
    var count: Int { requests.count }
    func send(path: String, method: String, token: String?, body: Data?) async throws -> Data {
        requests.append(.init(path: path, method: method, token: token, body: body)); throw HouseholdFailure.invitation
    }
}
@MainActor private final class InvitationTestVault: HouseholdVault {
    private var state = HouseholdVaultState()
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws { self.state = state }
}
