import SwiftUI

enum SleepTheme {
    static let accent = Color("SleepAccent")
    static let text = Color("SleepText")
    static let secondary = Color("SleepSecondary")
    static let success = Color("SleepSuccess")
    static let info = Color("SleepInfo")
    static let error = Color("SleepError")
    static let warning = Color("SleepWarning")
    static let primaryButton = Color("SleepPrimaryButton")
    static let primaryButtonText = Color("SleepPrimaryButtonText")
    static let bedLine = Color("SleepBedLine")
    static func canvas(_ scheme: ColorScheme) -> Color { Color("SleepCanvas") }
    static func surface(_ scheme: ColorScheme) -> Color { Color("SleepSurface") }
    static func border(_ scheme: ColorScheme) -> Color { Color("SleepBorder") }
}
