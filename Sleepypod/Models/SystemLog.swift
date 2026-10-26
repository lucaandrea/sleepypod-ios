import Foundation

enum SystemLogLevel: String, CaseIterable, Identifiable, Sendable {
    case all, info, warning, error = "err", debug
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .info: "Info"
        case .warning: "Warn"
        case .error: "Error"
        case .debug: "Debug"
        }
    }
    var priority: String? { self == .all ? nil : rawValue }
    // journalctl priority is a ceiling: Info includes warnings and errors too.
    static func detected(in message: String, floor: Self) -> Self {
        if message.range(of: #"\b(error|err|fatal|crit(ical)?|emerg|alert|exception)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .error }
        if message.range(of: #"\bwarn(ing)?\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .warning }
        if message.range(of: #"\bdebug\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .debug }
        return [.warning, .error].contains(floor) ? floor : .info
    }
}

struct SystemLogQuery: Hashable, Sendable {
    var unit: String?
    var lines = 200
    var level: SystemLogLevel = .all
    var validation: String? {
        guard let unit, unit.range(of: #"^sleepypod[\w.-]*\.service$"#, options: .regularExpression) != nil else { return "Choose an available sleepypod service." }
        guard (1...500).contains(lines) else { return "Choose between 1 and 500 lines." }
        return nil
    }
    var parameters: [String: String] {
        var parameters = ["unit": unit ?? "", "lines": String(lines)]
        parameters["priority"] = level.priority
        return parameters
    }
}

struct SystemLogPage: Decodable, Sendable { let lines: [String]; let nextCursor: String? }

struct SystemLogEntry: Identifiable, Sendable {
    let id: Int
    let raw: String
    let time: String
    let service: String
    let message: String
    let level: SystemLogLevel
    let json: String?

    init(raw: String, index: Int, floor: SystemLogLevel = .all) {
        self.id = index; self.raw = raw
        let parts = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        var message = raw
        // Split fields before parsing the message so timezone colons remain in the timestamp.
        if parts.count == 4, parts[0].range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil, parts[2].hasSuffix(":") {
            time = String(parts[0].dropFirst(11).prefix(8))
            service = String(parts[2].dropLast().split(separator: "[", maxSplits: 1).first ?? "")
            message = parts[3]
        } else { time = ""; service = "" }
        level = .detected(in: message, floor: floor)
        if message.contains("%7B") || message.contains("%22") { message = message.removingPercentEncoding ?? message }
        var pretty: String?
        if let start = message.firstIndex(of: "{"), let data = String(message[start...]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let decoded = String(data: encoded, encoding: .utf8) {
            pretty = decoded
            let prefix = String(message[..<start]).trimmingCharacters(in: .whitespaces)
            message = prefix.isEmpty ? "Structured log entry" : prefix
        }
        self.message = message; json = pretty
    }
}
