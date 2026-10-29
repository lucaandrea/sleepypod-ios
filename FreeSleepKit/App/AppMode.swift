import Foundation

enum AppMode {
    // Task-scoped test configuration avoids changing another invocation’s saved backend.
    @TaskLocal static var suppliedBackend: String?
    static var isCore: Bool {
        if let suppliedBackend { return suppliedBackend == "sleepypod-core" }
        if isDemo { return false }
        if let backend = UserDefaults.standard.string(forKey: "apiBackend"), ["free-sleep", "sleepypod-core"].contains(backend) {
            return backend == "sleepypod-core"
        }
        return !(UserDefaults.standard.string(forKey: "podURL")?.isEmpty == false
            && (UserDefaults.standard.string(forKey: "podNativeAPIPrefix") ?? "").isEmpty)
    }
    static var isDemo: Bool {
        if let suppliedBackend { return suppliedBackend == "demo" }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--demo") || UserDefaults.standard.string(forKey: "apiBackend") == "demo"
        #else
        return UserDefaults.standard.string(forKey: "apiBackend") == "demo"
        #endif
    }
    static func requireLiveConnection() throws {
        try PersonalWorkspaceBoundary.requireLegacyAccess()
        guard !isDemo else { throw PodError.message("System actions are unavailable in the demo. Open the app with your real Pod connection first.") }
    }
}
