import Foundation

struct ThermalLearning: Codable, Sendable {
    let model: String
    let mode: String
    let nights: Int
    let requiredNights: Int
    let trainingNights: Int
    let validationNights: Int
    let modelErrorF: Double?
    let baselineErrorF: Double?
    let suggestedOffsetF: Double?
    let reason: String
}
