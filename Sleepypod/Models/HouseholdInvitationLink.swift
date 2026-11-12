import Foundation

/// Reads the existing browser invitation format locally. Only explicit Join sends its single-use secret.
struct HouseholdInvitationLink: Equatable {
    let endpoint: URL
    let invitation: String
    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2048, !text.contains(where: { $0.isWhitespace }),
              var components = URLComponents(string: text),
              components.scheme == "http" || components.scheme == "https",
              components.user == nil, components.password == nil,
              components.percentEncodedPath == "/household/index.html", components.query == nil,
              let fragment = components.percentEncodedFragment,
              let items = URLComponents(string: "https://invitation.invalid/?" + fragment)?.queryItems,
              items.count == 1, items[0].name == "invite", let secret = items[0].value,
              HouseholdValidation.secret(secret), fragment == "invite=" + secret else { throw HouseholdFailure.invitation }
        components.path = ""; components.fragment = nil
        guard let origin = components.url else { throw HouseholdFailure.invitation }
        endpoint = try HouseholdHTTPClient.endpoint(origin.absoluteString)
        invitation = secret
    }
    static func url(endpoint: URL, invitation: String) -> URL? {
        guard HouseholdValidation.secret(invitation), let canonical = try? HouseholdHTTPClient.endpoint(endpoint.absoluteString),
              canonical == endpoint, var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/household/index.html"; components.fragment = "invite=" + invitation
        return components.url
    }
}

/// Editing or hiding an invitation withdraws its local review; it is never saved before explicit Join.
struct HouseholdInvitationDraft {
    private(set) var text = ""
    private(set) var reviewed: HouseholdInvitationLink?
    private(set) var error: String?
    mutating func edit(_ text: String) { self.text = text; reviewed = nil; error = nil }
    mutating func review() {
        do { reviewed = try HouseholdInvitationLink(text); error = nil }
        catch { reviewed = nil; self.error = "This is not a complete personal invitation link. Copy the whole link from your invitation, or ask the sender for a new one." }
    }
    mutating func clear() { self = Self() }
}
