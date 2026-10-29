import Foundation

/// Personal preparation never borrows the saved installation-owner connection.
public enum PersonalWorkspaceBoundary {
    public static let preferenceKey = "household.personalWorkspaceActive"
    @TaskLocal public static var suppliedActive: Bool?
    public static var isActive: Bool { suppliedActive ?? UserDefaults.standard.bool(forKey: preferenceKey) }
    public static func requireLegacyAccess() throws {
        guard !isActive else { throw PodError.message("Personal accounts are in preparation. Bed controls and Health access are unavailable in this workspace.") }
    }
}
