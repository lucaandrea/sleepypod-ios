import Foundation

/// DEBUG-only deep link for design QA: `-uiRoute schedule|sleep|week|weektrend|month|watch|stages|settings|allsettings|health|onboard1|onboard2`.
enum DebugRoute {
    static var personalComfortExample: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "uiComfortExample")
        #else
        false
        #endif
    }
    static var automationReplayFixture: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "uiAutomationReplay")
        #else
        false
        #endif
    }
    static var temperatureContextScenario: String {
        #if DEBUG
        UserDefaults.standard.string(forKey: "uiContextScenario") ?? "complete"
        #else
        "complete"
        #endif
    }
    static var baseScenario: String {
        #if DEBUG
        UserDefaults.standard.string(forKey: "uiBaseScenario") ?? "whole"
        #else
        "whole"
        #endif
    }
    static var current: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "uiRoute")
        #else
        nil
        #endif
    }

    /// DEBUG-only `-trainStageModel logistic|forest`: starts a personal model training run when the Stage models
    /// screen opens, so a device run can be driven from the command line.
    static var trainStageModel: StageModelKind? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "trainStageModel").flatMap(StageModelKind.init)
        #else
        nil
        #endif
    }

    /// DEBUG-only `-marketingCapture YES`: skips the notification prompt and the DEMO badge so App Store captures show the plain UI.
    static var marketingCapture: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "marketingCapture")
        #else
        false
        #endif
    }
}
