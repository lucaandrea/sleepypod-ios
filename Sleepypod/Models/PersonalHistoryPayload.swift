import Foundation

/// Pod presence, movement and HRV retain their source meanings; none are Watch sleep stages.
enum PersonalHistoryPayload: Codable, Equatable, Sendable {
    enum HRVMetric: String, Codable, Sendable { case windowVariability = "window_ibi_variability_v1", unknown }
    case presence(seconds: Double, exits: Int)
    case vitals(heartRate: Double?, breathingRate: Double?, hrv: Double?, metric: HRVMetric)
    case movement(total: Double)

    var kind: PersonalHistoryQuery.Kind {
        switch self {
        case .presence: .presence
        case .vitals: .vitals
        case .movement: .movement
        }
    }
    private enum CodingKeys: String, CodingKey {
        case kind, reportedPresenceSeconds, exits, interpretation, heartRateBpm, breathingRatePerMinute, hrvMs, hrvMetric, total
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(PersonalHistoryQuery.Kind.self, forKey: .kind) {
        case .presence:
            guard try values.decode(String.self, forKey: .interpretation) == "bed_presence_not_sleep" else { throw HouseholdFailure.invalid }
            self = .presence(seconds: try values.decode(Double.self, forKey: .reportedPresenceSeconds), exits: try values.decode(Int.self, forKey: .exits))
        case .vitals:
            self = .vitals(heartRate: try values.decodeIfPresent(Double.self, forKey: .heartRateBpm),
                           breathingRate: try values.decodeIfPresent(Double.self, forKey: .breathingRatePerMinute),
                           hrv: try values.decodeIfPresent(Double.self, forKey: .hrvMs), metric: try values.decode(HRVMetric.self, forKey: .hrvMetric))
        case .movement:
            guard try values.decode(String.self, forKey: .interpretation) == "movement_not_sleep_stage" else { throw HouseholdFailure.invalid }
            self = .movement(total: try values.decode(Double.self, forKey: .total))
        }
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        switch self {
        case let .presence(seconds, exits):
            try values.encode(seconds, forKey: .reportedPresenceSeconds); try values.encode(exits, forKey: .exits)
            try values.encode("bed_presence_not_sleep", forKey: .interpretation)
        case let .vitals(heartRate, breathingRate, hrv, metric):
            try values.encode(heartRate, forKey: .heartRateBpm); try values.encode(breathingRate, forKey: .breathingRatePerMinute)
            try values.encode(hrv, forKey: .hrvMs); try values.encode(metric, forKey: .hrvMetric)
        case let .movement(total):
            try values.encode(total, forKey: .total); try values.encode("movement_not_sleep_stage", forKey: .interpretation)
        }
    }
    func validate(intervalMilliseconds: Int64) throws {
        switch self {
        case let .presence(seconds, exits):
            guard seconds.isFinite, (0...86_400).contains(seconds), seconds * 1_000 <= Double(intervalMilliseconds),
                  (0...10_000).contains(exits) else { throw HouseholdFailure.invalid }
        case let .vitals(heartRate, breathingRate, hrv, _):
            guard heartRate.map({ $0.isFinite && $0 > 0 && $0 <= 300 }) ?? true,
                  breathingRate.map({ $0.isFinite && $0 > 0 && $0 <= 100 }) ?? true,
                  hrv.map({ $0.isFinite && (0...2_000).contains($0) }) ?? true else { throw HouseholdFailure.invalid }
        case let .movement(total):
            guard total.isFinite, total >= 0 else { throw HouseholdFailure.invalid }
        }
    }
}
