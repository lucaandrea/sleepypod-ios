import Foundation

enum AppMode {
    static var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--demo") || UserDefaults.standard.string(forKey: "apiBackend") == "demo"
        #else
        UserDefaults.standard.string(forKey: "apiBackend") == "demo"
        #endif
    }
    static func requireLiveConnection() throws {
        guard !isDemo else { throw PodError.message("System actions are unavailable in the demo. Open the app with your real Pod connection first.") }
    }
}
