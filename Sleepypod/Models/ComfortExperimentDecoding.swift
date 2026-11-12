import Foundation

/// Reject broader projections, missing null fields and unexpected nested data before exposing a personal response.
enum ComfortExperimentDecoding {
    private indirect enum Shape {
        case scalar
        case object([String: Shape], optional: [String: Shape] = [:])
        case array(Shape, maximum: Int)
        case nullable(Shape)
        case scope
        func validate(_ value: Any) throws {
            switch self {
            case .scalar: break // Codable checks the concrete scalar type afterward.
            case .nullable(let shape): if !(value is NSNull) { try shape.validate(value) }
            case .array(let shape, let maximum):
                guard let items = value as? [Any], items.count <= maximum else { throw HouseholdFailure.invalid }
                for item in items { try shape.validate(item) }
            case .object(let required, let optional):
                guard let object = value as? [String: Any], Set(required.keys).isSubset(of: Set(object.keys)),
                      Set(object.keys).isSubset(of: Set(required.keys).union(optional.keys)) else { throw HouseholdFailure.invalid }
                for (key, item) in object {
                    guard let shape = required[key] ?? optional[key] else { throw HouseholdFailure.invalid }
                    try shape.validate(item)
                }
            case .scope:
                guard let object = value as? [String: Any], let kind = object["kind"] as? String else { throw HouseholdFailure.invalid }
                let fields = kind == "legacy" ? "kind installationId" : "kind podId householdId accountId sleeperId sessionRevision assignmentRevision householdRevision"
                try Shape.object(ComfortExperimentDecoding.fields(fields)).validate(value)
            }
        }
    }
    private static func fields(_ names: String) -> [String: Shape] {
        Dictionary(uniqueKeysWithValues: names.split(separator: " ").map { (String($0), .scalar) })
    }
    private static func object(_ names: String, _ children: [String: Shape] = [:], optional: [String: Shape] = [:]) -> Shape {
        .object(fields(names).merging(children) { _, child in child }, optional: optional)
    }
    private static var context: Shape { object("subjectKey bindingHash routineHash wakeHash timezone baselineF minimumF maximumF") }
    private static var availability: Shape { object("reason", ["context": .nullable(context)]) }
    private static var night: Shape { object("date pair period role arm targetF") }
    private static var schedule: Shape {
        object("requestedFirstNightDate", [
            "windows": .array(object("date powerScheduleId windowStart windowEnd routineEnd endAction", [
                "wake": .nullable(object("at startsAt temperatureF vibrationSeconds source"))]), maximum: 16),
            "skipped": .array(object("date reason"), maximum: 63)])
    }
    private static var plan: Shape {
        object("version id createdAt firstNightDate variantF", ["context": context, "orders": .array(.scalar, maximum: 4)], optional: ["schedule": schedule])
    }
    private static var record: Shape {
        object("revision updatedAt status stoppedAt", ["plan": plan,
            "feedback": .array(object("nightDate recordedAt confirmedFullNight comfort unwantedAdjustments problem"), maximum: 16),
            "exposures": .array(object("nightDate recordedAt planHash bindingHash routineHash wakeHash sourceHash sourceState execution windowStart windowEnd wakeStartsAt targetF observedMs matchedTargetMs occupiedMs qualifiedMs manualChanges unconfirmedCommands safetyInterruptions attributionAmbiguous", optional: ["observationWindowId": .scalar]), maximum: 16)])
    }
    static func decode<Value: ComfortExperimentEnvelope>(_ type: Value.Type, data: Data) throws -> Value {
        guard data.count <= 524_288 else { throw HouseholdFailure.invalid }
        let schema: Shape
        let common = fields("version generatedAt").merging(["scope": Shape.scope]) { _, value in value }
        if type == ComfortExperimentLibrary.self {
            schema = .object(common.merging(fields("execution nextId")) { _, value in value }.merging([
                "availability": availability, "experiments": .array(object("id revision status createdAt updatedAt firstNightDate baselineF variantF contextCurrent"), maximum: 20)]) { _, value in value })
        } else if type == ComfortExperimentReview.self {
            schema = .object(common.merging(fields("execution reviewId planHash expiresAt notice")) { _, value in value }.merging([
                "availability": availability, "plan": plan, "nights": .array(night, maximum: 16), "schedule": schedule]) { _, value in value })
        } else if type == ComfortExperimentDetail.self {
            let arm = object("assigned scored usable missing meanComfort")
            schema = .object(common.merging(fields("execution contextCurrent contextReason")) { _, value in value }.merging([
                "record": record, "comparison": object("meanPairedComfortDifference recommendation reason interpretation", [
                    "nights": .array(object("date pair period role arm targetF usable comfort unwantedAdjustments problem", ["exclusions": .array(.scalar, maximum: 16)]), maximum: 16),
                    "arms": object("", ["baseline": arm, "variant": arm]),
                    "pairedDifferences": .array(object("pair comfort unwantedAdjustments"), maximum: 4)])]) { _, value in value })
        } else if type == ComfortExperimentExecution.self {
            schema = .object(common.merging(fields("planId planStatus controllerRunning state")) { _, value in value }.merging([
                "review": .nullable(object("id planHash createdAt expiresAt", ["sides": .array(.scalar, maximum: 2)])),
                "admission": .nullable(object("id admittedAt endsAt revokedAt reason", ["sides": .array(.scalar, maximum: 2)])),
                "applications": .array(object("id side requestedTargetF attemptedAt outcome acknowledgment finishedAt", [
                    "resolution": .nullable(object("observedAt resolvedAt targetF"))]), maximum: 2)]) { _, value in value })
        } else { throw HouseholdFailure.invalid }
        try schema.validate(JSONSerialization.jsonObject(with: data))
        return try JSONDecoder().decode(type, from: data)
    }
}
