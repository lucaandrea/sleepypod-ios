import Foundation

enum ConnectionIssue: Equatable {
    case authentication, unreachable, timedOut, unavailable, invalidResponse, unconfigured

    init(_ error: Error) {
        if let failure = error as? APIError {
            switch failure {
            case .networkError(let underlying): self.init(underlying); return
            case .invalidResponse(let code) where code == 401 || code == 403: self = .authentication
            case .noBaseURL: self = .unconfigured
            case .decodingFailed, .invalidResponse: self = .invalidResponse
            default: self = .unavailable
            }
        } else if let failure = error as? URLError {
            switch failure.code {
            case .timedOut: self = .timedOut
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: self = .unreachable
            default: self = .unavailable
            }
        } else { self = .unavailable }
    }
    var title: String {
        switch self {
        case .authentication: "Connection needs attention"
        case .unreachable: "Pod could not be reached"
        case .timedOut: "Pod did not respond"
        case .unavailable: "Connection interrupted"
        case .invalidResponse: "Pod response unavailable"
        case .unconfigured: "Connect your Pod"
        }
    }
    var detail: String {
        switch self {
        case .authentication: "The controller rejected access. Your saved key is still on this device. Retry or review Pod connection settings."
        case .unreachable: "Check the saved address and that this network can reach your Pod. Local controllers also need Local Network access in iOS Settings."
        case .timedOut: "The saved controller did not answer in time. Sleepypod will keep checking while the app is open."
        case .unavailable: "The connection to your saved controller was interrupted. Sleepypod will retry when the network changes and while the app is open."
        case .invalidResponse: "The controller replied, but its status could not be read. Check its software and connection settings."
        case .unconfigured: "Choose the address of your local or private remote controller."
        }
    }
}
