import SwiftUI

struct SidePicker: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        SleepSegmentedPicker(title: "Bed side", options: BedSide.allCases, selection: $model.side) { side in
            let name = model.settings?[side].name ?? ""
            return name.isEmpty ? side.title : name
        }
    }
}
