import Foundation

enum APIBackend: String, CaseIterable, Sendable {
    case freeSleep = "free-sleep"
    case sleepypodCore = "sleepypod-core"
    case demo = "demo"

    var displayName: String {
        switch self {
        case .freeSleep: "Existing Pod"
        case .sleepypodCore: "sleepypod"
        case .demo: "Demo Mode"
        }
    }

    var description: String {
        switch self {
        case .freeSleep: "Legacy server — some features may be incomplete or unsupported. Consider switching to sleepypod for smarter schedules, faster syncing, and better sleep insights."
        case .sleepypodCore: "You're on the best experience — smarter schedules, faster syncing, and deeper sleep insights."
        case .demo: "Explore the app with simulated pod data. No real hardware required."
        }
    }

    var isRecommended: Bool {
        self == .sleepypodCore
    }

    var isDemo: Bool {
        self == .demo
    }

    private static let demoClient = MockClient()

    func createClient() -> SleepypodProtocol {
        switch self {
        case .freeSleep:
            FreeSleepClient()
        case .sleepypodCore:
            SleepypodCoreClient()
        case .demo:
            Self.demoClient
        }
    }

    // MARK: - Persistence

    private static let key = "apiBackend"

    static var restoredLiveBackend: APIBackend {
        if let saved = UserDefaults.standard.string(forKey: "lastLiveBackend"),
           let backend = APIBackend(rawValue: saved), !backend.isDemo { return backend }
        return UserDefaults.standard.string(forKey: "podURL")?.isEmpty == false
            && (UserDefaults.standard.string(forKey: "podNativeAPIPrefix") ?? "").isEmpty ? .freeSleep : .sleepypodCore
    }

    static var current: APIBackend {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let backend = APIBackend(rawValue: raw) else {
                if UserDefaults.standard.string(forKey: "podURL")?.isEmpty == false,
                   (UserDefaults.standard.string(forKey: "podNativeAPIPrefix") ?? "").isEmpty { return .freeSleep }
                return .sleepypodCore
            }
            return backend
        }
        set {
            let previous = current
            if newValue.isDemo, !previous.isDemo {
                UserDefaults.standard.set(previous.rawValue, forKey: "lastLiveBackend")
            } else if !newValue.isDemo {
                UserDefaults.standard.set(newValue.rawValue, forKey: "lastLiveBackend")
                UserDefaults.standard.set(newValue == .sleepypodCore ? "native/v1" : "", forKey: "podNativeAPIPrefix")
            }
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
