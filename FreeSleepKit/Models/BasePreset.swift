import AppIntents

enum BasePreset: String, Codable, CaseIterable, AppEnum {
    case flat, sleep, relax, read
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Bed position")
    static let caseDisplayRepresentations: [BasePreset: DisplayRepresentation] = [
        .flat: "Flat", .sleep: "Sleep", .relax: "Relax", .read: "Read"
    ]
    var head: Double { switch self { case .flat: 0; case .sleep: 1; case .relax: 30; case .read: 40 } }
    var feet: Double { switch self { case .flat, .read: 0; case .sleep: 5; case .relax: 15 } }
}
