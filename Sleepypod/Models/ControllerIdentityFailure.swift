import Foundation

enum ControllerIdentityFailure: LocalizedError {
    case invalidReply, unavailable, differentInstallation, differentSavedInstallation, changedCredentials, invalidProfile

    var errorDescription: String? {
        switch self {
        case .invalidReply: "This address did not prove a fresh controller identity. Check its software and gateway configuration."
        case .unavailable: "A private connection check could not be created. Please try again."
        case .differentInstallation: "Home and Away identify different controllers. Use two addresses for the same controller. Your saved setup is unchanged."
        case .differentSavedInstallation: "This address now identifies a different controller. Verify addresses for your saved controller. Your saved setup is unchanged."
        case .changedCredentials: "A connection key or account changed. Verify these addresses again before using automatic connections."
        case .invalidProfile: "The saved automatic connection setup is unavailable. Your ordinary connection is unchanged."
        }
    }
}
