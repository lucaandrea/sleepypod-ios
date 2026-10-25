import AppIntents

enum ComfortMode: String, AppEnum {
    case off, preview, active
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Adaptive comfort mode")
    static let caseDisplayRepresentations: [ComfortMode: DisplayRepresentation] = [
        .off: "Off", .preview: "Preview suggestions", .active: "Adjust my routine",
    ]
}
