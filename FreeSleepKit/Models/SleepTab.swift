import Foundation

enum SleepTab: String, CaseIterable {
    case tonight = "Tonight", sleep = "Sleep", autopilot = "Autopilot", home = "Home", more = "More"
    var icon: String {
        switch self {
        case .tonight: "moon.stars"
        case .sleep: "chart.bar"
        case .autopilot: "sparkles"
        case .home: "house"
        case .more: "ellipsis.circle"
        }
    }
}
