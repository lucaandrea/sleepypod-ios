import Foundation

/// Names the failed user-entered connection without copying server replies or credentials into the UI.
struct OwnerRouteCheckFailure: LocalizedError {
    enum Connection: String { case home = "Home", away = "Away" }
    let connection: Connection
    let detail: String

    init(connection: Connection, error: Error) {
        self.connection = connection
        let underlying: Error
        if case APIError.networkError(let cause) = error { underlying = cause }
        else { underlying = error }
        if let transport = underlying as? URLError,
           [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired].contains(transport.code) {
            detail = "could not establish a secure connection. Check its address and certificate."
        } else if underlying is ControllerIdentityFailure {
            detail = "did not prove its controller identity. Check its address, controller software and gateway configuration."
        } else {
            switch ConnectionIssue(underlying) {
            case .authentication: detail = "rejected access. Check its connection key and gateway access."
            case .unreachable, .timedOut:
                detail = connection == .home
                    ? "could not be reached. Join your home Wi-Fi or check your private network route."
                    : "could not be reached. Check its HTTPS address and that the gateway is online."
            case .invalidResponse: detail = "did not return a usable controller reply. Check its address and gateway configuration."
            case .unconfigured: detail = "needs a complete controller address."
            case .unavailable: detail = "check was interrupted. Check its network route and retry."
            }
        }
    }

    var errorDescription: String? { "\(connection.rawValue) connection \(detail) Your saved setup is unchanged." }
}
