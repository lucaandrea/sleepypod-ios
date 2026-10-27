import Foundation
import FreeSleepKit

enum OwnerConnection {
    /// Includes key revisions without reading or retaining the key itself.
    static var revision: [String] {
        ["apiBackend", "podURL", "podIPAddress", "ownerConnectionRevision"].map { UserDefaults.standard.string(forKey: $0) ?? "" }
    }

    static var endpoint: URL? {
        guard let saved = UserDefaults.standard.string(forKey: "podURL"), !saved.isEmpty else { return nil }
        return URL(string: saved)
    }

    /// Discovery stores the host separately; show the same address used by the active clients.
    static var displayAddress: String {
        if let endpoint { return endpoint.absoluteString }
        guard let host = UserDefaults.standard.string(forKey: "podIPAddress"), !host.isEmpty else { return "" }
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = 3000
        return components.url?.absoluteString ?? ""
    }

    /// Match the exact saved origin; discovery probes must never receive another Pod's key.
    static func authorize(_ request: URLRequest, token suppliedToken: String? = nil) -> URLRequest {
        guard let endpoint, let url = request.url,
              endpoint.host == url.host,
              endpoint.port == url.port,
              endpoint.scheme == url.scheme else { return request }
        var authorized = request
        let token = suppliedToken ?? UnifiedRuntime.savedKey(for: endpoint.absoluteString)
        if !token.isEmpty { authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return authorized
    }

    static let session = URLSession(configuration: .ephemeral, delegate: OwnerRedirectPolicy(), delegateQueue: nil)

    static var streamURL: URL? {
        guard let endpoint else { return nil }
        if let saved = UserDefaults.standard.string(forKey: "podStreamURL"), !saved.isEmpty,
           let stream = URL(string: saved), stream.host == endpoint.host,
           stream.scheme == (endpoint.scheme == "https" ? "wss" : "ws") { return stream }
        guard endpoint.scheme == "http" else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.scheme = "ws"; components?.port = 3001; components?.path = ""
        return components?.url
    }

    static func streamRequest(for url: URL, token suppliedToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        if let endpoint, url == streamURL {
            let token = suppliedToken ?? UnifiedRuntime.savedKey(for: endpoint.absoluteString)
            if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        }
        return request
    }
}

private final class OwnerRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
