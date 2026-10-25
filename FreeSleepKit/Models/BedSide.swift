import AppIntents

enum BedSide: String, Codable, CaseIterable, AppEnum {
    case left, right
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bed side")
    static let caseDisplayRepresentations: [BedSide: DisplayRepresentation] = [.left: "Left side", .right: "Right side"]
    var title: String { self == .left ? "Left side" : "Right side" }
}
