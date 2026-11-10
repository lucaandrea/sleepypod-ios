import Foundation

/// Progress describes evidence for a fit; it never grants permission to select a model or control hardware.
struct LearningJourneyStep: Equatable {
    struct Progress: Equatable {
        let reviewed: Int
        let required: Int
        var fraction: Double { min(1, Double(max(0, reviewed)) / Double(max(1, required))) }
    }
    let title: String
    let state: String
    let purpose: String
    let next: String
    var progress: Progress?

    static func stages(inventory: PodStageModelResponse?, reviewed: Int?, required: Int) -> Self {
        let state: String
        if let inventory {
            state = inventory.model == nil ? "Rules are available" : inventory.active == true ? "Pod model selected"
                : inventory.active == false ? "Candidate saved" : "Candidate saved · selection unknown"
        } else { state = "Needs a current Pod read" }
        return .init(title: "Sleep-stage estimates", state: state,
            purpose: "Estimates how a night was spent asleep. Watch stages help compare personal models; they are not clinical ground truth.",
            next: "Record matching complete Watch and Pod nights on your usual side. Review the nights, then compare a fit against simpler estimates on unseen nights.",
            progress: reviewed.map { .init(reviewed: max(0, $0), required: required) })
    }

    static func baseline(saved: Bool, verified: Bool, referenceEnd: Date?, trainedAt: Date?, loaded: Bool,
                         reviewed: Int, required: Int, now: Date) -> Self {
        let recent = referenceEnd.map { $0 <= now && now.timeIntervalSince($0) <= 45 * 86_400 } == true
        let validDate = trainedAt.map { $0 <= now } == true
        return .init(title: "Personal night baseline",
            state: saved ? (verified && recent && validDate ? "Baseline verified" : "Refresh to verify") : "Needs reviewed Health nights",
            purpose: "Learns your usual sleep duration and timing, then compares later nights. This private model does not choose bed temperature or classify sleep stages.",
            next: saved ? "Refresh the original Health source and review a later complete night before interpreting differences. A saved model can need rechecking."
                : "Choose one Health source. Confirm genuine complete nights, fit your baseline, then verify it against current records.",
            progress: loaded ? .init(reviewed: max(0, reviewed), required: required) : nil)
    }

    static func temperature(_ status: ThermalModelStatus?) -> Self {
        guard let status else {
            return .init(title: "Temperature learning", state: "Needs a current Pod read",
                purpose: "Learns from complete bed and room recordings paired with your comfort check-ins.",
                next: "Connect to an updated Pod, then refresh to see which nights qualify.")
        }
        let state: String, next: String
        if let model = status.model {
            state = !model.current ? "Recheck changed evidence" : model.validation.passesFeedbackCheck ? "Research comparison passed" : "Comparison needs improvement"
            next = !model.current ? "Review changed nights and settings before retraining."
                : model.validation.passesFeedbackCheck ? "Inspect Preview proposals and the independent hardware and reviewed-night activation requirements."
                : "Inspect the held-out comparison. A successful fit does not establish that the model is useful."
        } else {
            state = status.canTrain ? "Ready to review a fit" : "Collecting reviewed nights"
            next = status.canTrain ? "Review the included nights, train on the Pod, then inspect its comparison on later unseen nights."
                : "Review complete nights and add a warm, cold or comfortable check-in. Health history alone cannot replace bed temperatures."
        }
        return .init(title: "Temperature learning", state: state,
            purpose: "Learns comfort feedback from bed and room conditions. Fitting does not activate overnight adjustments.", next: next,
            progress: .init(reviewed: status.completeNights, required: status.requiredNights))
    }
}
