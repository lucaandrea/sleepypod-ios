import Foundation

/// Preserve complete finite JSON configuration and evidence documents across typed API boundaries.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
    subscript(_ key: String) -> Self? { if case .object(let object) = self { object[key] } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self, value.isFinite { value } else { nil } }
    var strings: [String]? { if case .array(let values) = self { values.compactMap(\.string) } else { nil } }
}

extension JSONValue {
    func value(at path: String) -> Self? { path.split(separator: ".").reduce(Optional(self)) { $0?[String($1)] } }
    func replacing(at path: String, with value: Self) throws -> Self {
        var parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first, case .object(var fields) = self, fields[first] != nil else { throw APIError.serverError(message: "Unknown profile parameter: \(path)") }
        parts.removeFirst()
        fields[first] = parts.isEmpty ? value : try fields[first]!.replacing(at: parts.joined(separator: "."), with: value)
        return .object(fields)
    }
    static func encoded<Value: Encodable>(_ value: Value) throws -> Self { try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
    var formattedJSON: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "Invalid value"
    }
}
