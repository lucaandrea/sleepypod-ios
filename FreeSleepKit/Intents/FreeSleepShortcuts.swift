import AppIntents

struct FreeSleepShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetTemperatureIntent(), phrases: ["Set my bed temperature with \(.applicationName)"],
            shortTitle: "Bed temperature", systemImageName: "thermometer.medium")
        AppShortcut(intent: SetPowerIntent(), phrases: ["Turn on my bed with \(.applicationName)"],
            shortTitle: "Bed power", systemImageName: "power")
        AppShortcut(intent: SetBasePresetIntent(), phrases: ["Set my bed position with \(.applicationName)"],
            shortTitle: "Bed position", systemImageName: "bed.double")
        AppShortcut(intent: StopBaseIntent(), phrases: ["Stop my bed with \(.applicationName)"],
            shortTitle: "Stop bed", systemImageName: "stop.circle")
        AppShortcut(intent: SleepSummaryIntent(), phrases: ["My sleep routine in \(.applicationName)"],
            shortTitle: "Sleep routine", systemImageName: "chart.bar")
        AppShortcut(intent: SetBaseAnglesIntent(), phrases: ["Set my bed angles with \(.applicationName)"],
            shortTitle: "Head and feet angles", systemImageName: "angle")
        AppShortcut(intent: SyncHealthIntent(), phrases: ["Sync Health with \(.applicationName)"],
            shortTitle: "Sync Apple Health", systemImageName: "heart")
        AppShortcut(intent: SetComfortIntent(), phrases: ["Set adaptive comfort with \(.applicationName)"],
            shortTitle: "Adaptive comfort", systemImageName: "thermometer.variable")
        AppShortcut(intent: SetAwayModeIntent(), phrases: ["Set Away mode with \(.applicationName)"],
            shortTitle: "Away mode", systemImageName: "suitcase")
        AppShortcut(intent: PrimePodIntent(), phrases: ["Prime my Pod with \(.applicationName)"],
            shortTitle: "Prime Pod", systemImageName: "drop")
    }
}
