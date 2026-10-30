#if DEBUG
import Foundation

@MainActor final class PersonalHistoryPreviewVault: HouseholdVault {
    var state: HouseholdVaultState
    init(state: HouseholdVaultState) { self.state = state }
    func load() throws -> HouseholdVaultState { state }
    func save(_ state: HouseholdVaultState) throws { self.state = state }
}
#endif
