import Foundation
import HomeKit
import Observation

struct HomeSceneSummary: Identifiable { let id: UUID; let name: String }
struct HomeSummary: Identifiable { let id: UUID; let name: String; let scenes: [HomeSceneSummary] }

enum HomeAccessState: Equatable {
    case idle, waiting, restricted, denied, loading, ready, empty
    static func resolve(_ status: HMHomeManagerAuthorizationStatus, loaded: Bool, homeCount: Int) -> Self {
        if status.contains(.restricted) { return .restricted }
        if status.contains(.authorized) { return loaded ? (homeCount == 0 ? .empty : .ready) : .loading }
        return status.contains(.determined) ? .denied : .waiting
    }
    var message: String {
        switch self {
        case .idle: "Authorize Apple Home access on this iPhone to list and run your existing scenes."
        case .waiting: "Waiting for Apple Home access…"
        case .restricted: "Apple Home access is unavailable. Check sleepypod in iPhone Settings; device restrictions may also apply."
        case .denied: "Apple Home access is off. Enable it for sleepypod in iPhone Settings, then return here."
        case .loading: "Loading your homes…"
        case .empty: "Apple Home access is allowed. Create or join a home in the Home app to use scenes."
        case .ready: "Choose an existing scene to run. Its actions may affect other accessories in your home."
        }
    }
}

@MainActor @Observable
final class HomeSceneExecution {
    private(set) var runningID: UUID?
    private(set) var message: String?
    private(set) var failed = false
    // One scene at a time avoids duplicate execution while HomeKit acknowledges the action.
    func run(id: UUID, name: String, action: () async throws -> Void) async {
        guard runningID == nil else { return }
        runningID = id; message = nil; failed = false
        defer { runningID = nil }
        do { try await action(); message = "Ran \(name)." }
        catch { failed = true; message = error.localizedDescription }
    }
}

@MainActor @Observable
final class AppleHomeService: NSObject, HMHomeManagerDelegate, HMHomeDelegate {
    private(set) var homes: [HomeSummary] = []
    private(set) var state: HomeAccessState = .idle
    let execution = HomeSceneExecution()
    private var manager: HMHomeManager?
    private var loaded = false

    func connect() {
        if manager == nil { manager = HMHomeManager(); manager?.delegate = self }
        refresh()
    }
    func refresh() {
        guard let manager else { return }
        state = .resolve(manager.authorizationStatus, loaded: loaded, homeCount: manager.homes.count)
        guard state == .ready else { homes = []; return }
        homes = manager.homes.map { home in
            home.delegate = self
            return HomeSummary(id: home.uniqueIdentifier, name: home.name,
                scenes: home.actionSets.map { .init(id: $0.uniqueIdentifier, name: $0.name) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in self?.loaded = true; self?.refresh() }
    }
    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
    nonisolated func homeDidUpdateName(_ home: HMHome) { updateScenes() }
    nonisolated func home(_ home: HMHome, didAdd actionSet: HMActionSet) { updateScenes() }
    nonisolated func home(_ home: HMHome, didRemove actionSet: HMActionSet) { updateScenes() }
    nonisolated func home(_ home: HMHome, didUpdateNameFor actionSet: HMActionSet) { updateScenes() }
    private nonisolated func updateScenes() { Task { @MainActor [weak self] in self?.refresh() } }
    func run(_ scene: HomeSceneSummary, in house: HomeSummary) async {
        await execution.run(id: scene.id, name: scene.name) {
            guard manager?.authorizationStatus.contains(.authorized) == true,
                  let home = manager?.homes.first(where: { $0.uniqueIdentifier == house.id }),
                  let action = home.actionSets.first(where: { $0.uniqueIdentifier == scene.id }) else {
                throw PodError.message("This scene is no longer available. Refresh Apple Home and choose it again.")
            }
            try await home.executeActionSet(action)
        }
    }
}
