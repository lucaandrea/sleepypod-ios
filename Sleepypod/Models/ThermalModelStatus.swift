import Foundation

struct ThermalModelStatus: Decodable, Sendable {
    struct Exclusion: Decodable, Sendable, Identifiable {
        let date: String
        let reason: String
        var id: String { date }
    }
    struct Model: Decodable, Sendable {
        struct Validation: Decodable, Sendable {
            let modelMae: Double
            let holdMae: Double
            let averageMae: Double
            let passesFeedbackCheck: Bool
            let reason: String
        }
        let id: String
        let current: Bool
        let trainingDates: [String]
        let validationDates: [String]
        let validation: Validation
    }
    let apiVersion: Int
    let side: Side
    let requiredNights: Int
    let completeNights: Int
    let feedbackNights: Int
    let datasetHash: String
    let canTrain: Bool
    let excluded: [Exclusion]
    let model: Model?
    let reason: String
    var generatedAt: Double?
}
