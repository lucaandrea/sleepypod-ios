import Foundation

struct BaseAngles: Codable, Sendable, Equatable {
    var head: Double
    var feet: Double
    static let flat = Self(head: 0, feet: 0)
    var valid: Bool { head.isFinite && feet.isFinite && (0...60).contains(head) && (0...45).contains(feet) }
    var label: String { valid ? "\(Int(head))° / \(Int(feet))°" : "Unavailable" }
}

struct BasePositions: Codable, Sendable, Equatable {
    var left: BaseAngles
    var right: BaseAngles
    static let flat = Self(left: .flat, right: .flat)
    subscript(side: BaseScope) -> BaseAngles {
        get { side == .right ? right : left }
        set {
            if side != .right { left = newValue }
            if side != .left { right = newValue }
        }
    }
}

enum BaseScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case both, left, right
    var id: String { rawValue }
    var sides: [String] { self == .both ? ["left", "right"] : [rawValue] }
    func overlaps(_ other: Self) -> Bool { self == .both || other == .both || self == other }
}

enum BasePreset: String, CaseIterable, Identifiable, Sendable {
    case flat, sleep, relax, read
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var angles: BaseAngles {
        switch self {
        case .flat: .flat
        case .sleep: BaseAngles(head: 1, feet: 5)
        case .relax: BaseAngles(head: 30, feet: 15)
        case .read: BaseAngles(head: 40, feet: 0)
        }
    }
}

struct UnifiedBaseStatus: Decodable, Sendable {
    struct Movement: Decodable, Sendable { var left: Bool?; var right: Bool? }
    var state: String
    var position: BasePositions?
    var stale: Bool
    var busy: Bool
    var lastUpdate: Double?
    var error: String?
    var independentControl: Bool?
    var movingBySide: Movement?
    var moving: Bool?
    var splitBase: Bool?
    var ready: Bool { state == "connected" && !stale && !busy && position?.left.valid == true && position?.right.valid == true }
    func isMoving(_ scope: BaseScope) -> Bool {
        if let movement = movingBySide {
            return (scope != .right && movement.left == true) || (scope != .left && movement.right == true)
        }
        return moving == true
    }
}

enum BaseScheduleDays: String, Codable, CaseIterable, Identifiable, Sendable {
    case daily, weekdays, weekends, sunday, monday, tuesday, wednesday, thursday, friday, saturday
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var numbers: Set<Int> {
        switch self {
        case .daily: Set(0...6)
        case .weekdays: Set(1...5)
        case .weekends: [0, 6]
        default: [Self.allCases.firstIndex(of: self)! - 3]
        }
    }
}

/// Mirrors Core's whole-row schedule contract; all fields survive toggling or editing.
struct BaseSchedule: Codable, Sendable, Identifiable, Equatable {
    var id: Int?
    var dayOfWeek: BaseScheduleDays = .daily
    var side: BaseScope = .both
    var presetName = "Sleep"
    var time = "22:00"
    var enabled = true
    var head = 1
    var feet = 5
    var feedRate = 50
    var angles: BaseAngles { BaseAngles(head: Double(head), feet: Double(feet)) }
    var valid: Bool {
        let parts = time.split(separator: ":", omittingEmptySubsequences: false)
        return angles.valid && (30...100).contains(feedRate) && !presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && presetName.count <= 40 && parts.count == 2 && parts.allSatisfy { $0.count == 2 }
            && (0...23).contains(Int(parts.first ?? "") ?? -1) && (0...59).contains(Int(parts.last ?? "") ?? -1)
    }
    func conflicts(with other: Self) -> Bool {
        (id == nil || id != other.id) && time == other.time && side.overlaps(other.side)
            && !dayOfWeek.numbers.isDisjoint(with: other.dayOfWeek.numbers)
    }
}

struct BaseMoveRequest: Encodable, Sendable, Equatable {
    let head: Int
    let feet: Int
    let feedRate: Int
    let sides: [String]
    init(angles: BaseAngles, speed: Int, scope: BaseScope) {
        head = Int(angles.head); feet = Int(angles.feet); feedRate = speed; sides = scope.sides
    }
}
