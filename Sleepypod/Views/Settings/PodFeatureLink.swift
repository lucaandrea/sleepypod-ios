import SwiftUI
import FreeSleepKit

struct PodFeatureLink: View {
    let feature: PodFeature
    let icon: String
    var tile = false
    @Environment(DeviceManager.self) private var device
    init(_ feature: PodFeature, icon: String, tile: Bool = false) {
        self.feature = feature; self.icon = icon; self.tile = tile
    }
    var body: some View {
        NavigationLink {
            Group {
                if feature == .comfort { PersonalComfortDestination(side: device.selectedSide.primarySide) }
                else if feature == .alarms, APIBackend.current != .freeSleep { NativeNextAlarmScreen(side: device.selectedSide.primarySide) }
                else if feature == .journal { MorningJournalDestination(side: device.selectedSide.primarySide) }
                else if feature == .routines { BedtimeRoutinesDestination(side: device.selectedSide.primarySide) }
                else if feature == .history, APIBackend.current != .freeSleep { ImportedHistoryScreen(side: device.selectedSide.primarySide) }
                else {
                    PodFeatureScreen(feature, side: device.selectedSide.primarySide.rawValue,
                                     homeContent: feature == .home && APIBackend.current != .freeSleep ? AnyView(HomeRoomSummaryCard(compact: true)) : nil)
                }
            }.toolbar(.visible, for: .navigationBar)
        } label: {
            SettingsRow(feature == .history && APIBackend.current != .freeSleep ? "Imported history" : feature.title,
                        icon: icon, tile: tile, chevron: true)
        }
    }
}
