import Foundation

/// Parse bounded text only; normalization, time interpretation and scoring remain server responsibilities.
enum ReferenceTextParser {
    enum Format: String, CaseIterable, Sendable { case csv, json }
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumRows = 2000
    private static let columns: Set<String> = ["recordKey", "subjectId", "metric", "value", "unit", "timestampMs", "startMs", "endMs", "timestamp", "start", "end", "aggregation", "windowMs", "quality", "annotation"]
    private static let numeric: Set<String> = ["timestampMs", "startMs", "endMs", "windowMs", "quality", "value"]

    static func parse(_ text: String, format: Format) throws -> [JSONValue] {
        guard text.utf8.count <= maximumBytes else { throw failure("Reference text exceeds 2 MiB.") }
        let rows: [JSONValue]
        switch format {
        case .json:
            let data = Data(text.utf8)
            let raw: Any
            do { raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
            catch { throw failure("Expected a JSON array of reference records.") }
            guard let values = raw as? [Any], values.count <= maximumRows else { throw failure("Expected at most 2000 reference records.") }
            try checkBounds(values)
            rows = try JSONDecoder().decode([JSONValue].self, from: data)
        case .csv: rows = try parseCSV(text)
        }
        guard !rows.isEmpty else { throw failure("Supply at least one reference record.") }
        return rows
    }

    /// Account for the enclosing import's side/source/subject fields before decoding recursive JSON values.
    private static func checkBounds(_ rows: [Any]) throws {
        var pending: [(value: Any, depth: Int)] = [(rows, 1)]
        var nodes = 4
        while let entry = pending.popLast() {
            nodes += 1
            guard nodes <= 100000, entry.depth <= 12 else { throw failure("Reference JSON is too large or deeply nested.") }
            if let values = entry.value as? [Any] {
                pending.append(contentsOf: values.map { ($0, entry.depth + 1) })
            } else if let fields = entry.value as? [String: Any] {
                pending.append(contentsOf: fields.values.map { ($0, entry.depth + 1) })
            } else if let number = entry.value as? NSNumber, !number.doubleValue.isFinite {
                throw failure("Reference values must be finite JSON numbers.")
            }
        }
    }

    /// Quoted CSV supports escaped quotes and embedded newlines; empty cells are omitted, never evaluated.
    private static func parseCSV(_ text: String) throws -> [JSONValue] {
        let input = text.first == "\u{FEFF}" ? String(text.dropFirst()) : text
        var cursor = input.startIndex
        var records: [[String]] = []
        var record: [String] = []
        var cell = "", quoted = false, closed = false
        func endCell() throws {
            record.append(cell)
            guard record.count <= columns.count else { throw failure("Too many CSV columns.") }
            cell = ""; closed = false
        }
        func endRecord() throws {
            try endCell(); records.append(record); record = []
            guard records.count <= maximumRows + 1 else { throw failure("Expected at most 2000 reference records.") }
        }
        while cursor < input.endIndex {
            let character = input[cursor]; cursor = input.index(after: cursor)
            if quoted {
                if character == "\"" {
                    if cursor < input.endIndex, input[cursor] == "\"" { cell.append("\""); cursor = input.index(after: cursor) }
                    else { quoted = false; closed = true }
                } else { cell.append(character) }
            } else if character == "," { try endCell() }
            else if character == "\n" || character == "\r" || character == "\r\n" {
                if character == "\r", cursor < input.endIndex, input[cursor] == "\n" { cursor = input.index(after: cursor) }
                try endRecord()
            } else if closed { throw failure("Unexpected data after a quoted CSV cell.") }
            else if character == "\"" {
                guard cell.isEmpty else { throw failure("A quote must start a CSV cell.") }
                quoted = true
            } else { cell.append(character) }
        }
        guard !quoted else { throw failure("Unterminated quoted CSV cell.") }
        if !cell.isEmpty || !record.isEmpty || closed { try endRecord() }
        guard let header = records.first, Set(header).count == header.count, header.allSatisfy(columns.contains) else {
            throw failure("CSV headers must be unique documented field names.")
        }
        return try records.dropFirst().map { values in
            guard values.count == header.count else { throw failure("A CSV row has a different number of fields than the header.") }
            var fields: [String: JSONValue] = [:]
            for (key, value) in zip(header, values) where !value.isEmpty {
                if numeric.contains(key), value.range(of: #"^-?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil {
                    guard let number = Double(value), number.isFinite else { throw failure("Reference values must be finite JSON numbers.") }
                    fields[key] = .number(number)
                } else { fields[key] = .string(value) }
            }
            return .object(fields)
        }
    }
    private static func failure(_ message: String) -> ReferenceTextError { .init(message: message) }
}

struct ReferenceTextError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
