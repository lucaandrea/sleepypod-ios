import Foundation

enum APIError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse(statusCode: Int)
    case decodingFailed(Error)
    case encodingFailed(Error)
    case networkError(Error)
    case serverError(message: String)
    case noBaseURL
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid URL"
        case .invalidResponse(let code):
            "Server returned status \(code)"
        case .decodingFailed(let error):
            "Failed to decode response: \(error.localizedDescription)"
        case .encodingFailed(let error):
            "Failed to encode request: \(error.localizedDescription)"
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .serverError(let message):
            "Server error: \(message)"
        case .noBaseURL:
            "Pod IP address not configured"
        case .notSupported(let feature):
            "Not supported: \(feature)"
        }
    }
    /// Keep recoverable connection failures readable without exposing URL-loading error codes.
    static func message(for error: Error) -> String {
        if case APIError.networkError(let underlying) = error { return message(for: underlying) }
        guard let network = error as? URLError else { return error.localizedDescription }
        switch network.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "The controller connection is offline. Check your network and reload."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "The controller could not be reached. Check its address and reload."
        case .timedOut:
            return "The controller did not respond in time. Reload to check its current state."
        default: return error.localizedDescription
        }
    }

}
