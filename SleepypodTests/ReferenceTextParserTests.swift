import XCTest
@testable import Sleepypod

final class ReferenceTextParserTests: XCTestCase {
    func testLiteralCoreParserFixturesMatchNativeResults() throws {
        struct Fixture: Decodable { let name: String; let format: String; let text: String; let rows: [JSONValue] }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "reference-parser", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.count, 5)
        for fixture in fixtures {
            let format = try XCTUnwrap(ReferenceTextParser.Format(rawValue: fixture.format))
            XCTAssertEqual(try ReferenceTextParser.parse(fixture.text, format: format), fixture.rows, fixture.name)
        }
    }
    func testQuotedCSVPreservesSourceTextAndConvertsOnlyNumericColumns() throws {
        let csv = "\u{FEFF}recordKey,metric,value,unit,timestamp,annotation\r\n1,heart_rate,6e1,bpm,2026-10-10T23:00:00Z,\"Line one\r\nLine \"\"two\"\" café\"\r\n"
        let rows = try ReferenceTextParser.parse(csv, format: .csv)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["recordKey"], .string("1"))
        XCTAssertEqual(rows[0]["value"], .number(60))
        XCTAssertEqual(rows[0]["annotation"], .string("Line one\r\nLine \"two\" café"))
        XCTAssertEqual(rows[0]["timestamp"], .string("2026-10-10T23:00:00Z"))
    }
    func testStageLabelsFormulaTextAndEmptyCellsAreNeverInterpreted() throws {
        let csv = "recordKey,metric,value,unit,annotation\n1,sleep_stages,deep,stage,=SUM(A1:A2)\n2,heart_rate,+60,bpm,\n"
        let rows = try ReferenceTextParser.parse(csv, format: .csv)
        XCTAssertEqual(rows[0]["value"], .string("deep"))
        XCTAssertEqual(rows[0]["annotation"], .string("=SUM(A1:A2)"))
        XCTAssertEqual(rows[1]["value"], .string("+60"))
        XCTAssertNil(rows[1]["annotation"])
    }
    func testMalformedCSVDoesNotSilentlyChangeRecords() {
        for text in ["recordKey,recordKey\n1,2", "unknown\n1", "recordKey,value\n1", "recordKey\n\"open", "recordKey\n\"closed\" trailing", "recordKey\nbad\"quote", "recordKey,value\n1,2\n\n"] {
            XCTAssertThrowsError(try ReferenceTextParser.parse(text, format: .csv), text)
        }
    }
    func testJSONRowsRemainUnnormalizedForServerPreview() throws {
        let text = #"[{"recordKey":"sample","value":12,"unknown":{"items":[true,null,"text"]}},17]"#
        let rows = try ReferenceTextParser.parse(text, format: .json)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["unknown"], .object(["items": .array([.bool(true), .null, .string("text")])]))
        XCTAssertEqual(rows[1], .number(17), "The preview must report rejected row counts; parsing must not drop rows.")
    }
    func testResourceAndShapeLimitsFailBeforeRecursiveModelDecode() {
        for text in ["{}", "[]", "[", "[1e309]", String(repeating: "[", count: 14) + "0" + String(repeating: "]", count: 14)] {
            XCTAssertThrowsError(try ReferenceTextParser.parse(text, format: .json))
        }
        let tooMany = "[" + Array(repeating: "0", count: 2001).joined(separator: ",") + "]"
        XCTAssertThrowsError(try ReferenceTextParser.parse(tooMany, format: .json))
        XCTAssertThrowsError(try ReferenceTextParser.parse(String(repeating: "é", count: 1_048_577), format: .csv))
        XCTAssertThrowsError(try ReferenceTextParser.parse("recordKey,value\n1,1e309", format: .csv))
    }
}
