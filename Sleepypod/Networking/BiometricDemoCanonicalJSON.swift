import CryptoKit
import Foundation

/// Core's finite-binary64-json-v1 encoding, used only to identify in-memory Demo protocols.
enum BiometricDemoCanonicalJSON {
    static func hash(_ value: some Encodable) throws -> String {
        let text = try canonical(.encoded(value))
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func canonical(_ value: JSONValue) throws -> String {
        var nodes = 0
        func visit(_ item: JSONValue, depth: Int) throws -> String {
            nodes += 1
            guard nodes <= 20000, depth <= 32 else { throw invalid }
            switch item {
            case .null: return "null"
            case .bool(let value): return value ? "true" : "false"
            case .number(let value): return try number(value)
            case .string(let value): return try quoted(value)
            case .array(let values): return "[" + (try values.map { try visit($0, depth: depth + 1) }).joined(separator: ",") + "]"
            case .object(let values):
                let keys = values.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
                let fields = try keys.map { key in
                    try visit(.string(key), depth: depth + 1) + ":" + visit(values[key]!, depth: depth + 1)
                }
                return "{" + fields.joined(separator: ",") + "}"
            }
        }
        return try visit(value, depth: 0)
    }
    private static func quoted(_ value: String) throws -> String {
        guard value.utf16.count <= 65536 else { throw invalid }
        let escaped = value.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 8: "\\b"
            case 9: "\\t"
            case 10: "\\n"
            case 12: "\\f"
            case 13: "\\r"
            case 34: "\\\""
            case 92: "\\\\"
            case 0...31: String(format: "\\u%04x", scalar.value)
            default: String(scalar)
            }
        }.joined()
        return "\"" + escaped + "\""
    }
    /// Expand the binary coefficient exactly using base-ten digits; ordinary float printers round it.
    private static func number(_ value: Double) throws -> String {
        guard value.isFinite else { throw invalid }
        if value == 0 { return "0" }
        let bits = abs(value).bitPattern
        let exponent = Int((bits >> 52) & 2047)
        let coefficient = (bits & ((1 << 52) - 1)) + (exponent == 0 ? 0 : 1 << 52)
        let power = max(exponent, 1) - 1023 - 52
        var digits = String(coefficient).reversed().compactMap { $0.wholeNumberValue }
        for _ in 0..<abs(power) {
            var carry = 0
            for index in digits.indices {
                let product = digits[index] * (power < 0 ? 5 : 2) + carry
                digits[index] = product % 10; carry = product / 10
            }
            while carry > 0 { digits.append(carry % 10); carry /= 10 }
        }
        var token = digits.reversed().map(String.init).joined()
        if power < 0 {
            let places = -power
            token = String(repeating: "0", count: max(0, places + 1 - token.count)) + token
            token.insert(".", at: token.index(token.endIndex, offsetBy: -places))
            while token.last == "0" { token.removeLast() }
            if token.last == "." { token.removeLast() }
        }
        return (value < 0 ? "-" : "") + token
    }
    private static var invalid: ReferenceTextError { .init(message: "The synthetic protocol cannot be represented in Core's canonical format.") }
}
