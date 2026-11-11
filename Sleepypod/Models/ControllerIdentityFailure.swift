import Foundation

enum ControllerIdentityFailure: LocalizedError {
    case invalidReply, unavailable, differentInstallation, changedCredentials, invalidProfile

    var errorDescription: String? {
        switch self {
        case .invalidReply: "This address did not prove a fresh controller identity. Check its software and gateway configuration."
        case .unavailable: "A private connection check could not be created. Please try again."
        case .differentInstallation: "These addresses identify different controller installations. They cannot be used as automatic alternatives."
        case .changedCredentials: "A connection key or account changed. Verify these addresses again before using automatic connections."
        case .invalidProfile: "The saved automatic connection setup is unavailable. Your ordinary connection is unchanged."
        }
    }
}
