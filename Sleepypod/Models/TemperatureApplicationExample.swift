import Foundation

/// Source-generated synthetic audit records, isolated from the live transport.
struct TemperatureApplicationExample: TemperatureApplicationClient {
    let scenario: String
    func available() async throws {
        if scenario == "unavailable" {
            throw APIError.serverError(message: "This controller does not offer temperature application history yet.")
        }
    }
    func read(side: Side, before: Int?) async throws -> TemperatureApplicationPage {
        struct Fixture: Decodable { let synthetic: Bool; let cases: [String: TemperatureApplicationPage] }
        guard let url = Bundle.main.url(forResource: "temperature-applications-example", withExtension: "json") else {
            throw TemperatureApplicationPage.invalid
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let name: String
        if side == .right { name = "otherSide" }
        else if scenario == "empty" { name = "empty" }
        else if scenario == "attempting" { name = "attempting" }
        else if scenario == "pages" { name = before == nil ? "firstPage" : "secondPage" }
        else { name = "unknown" }
        guard fixture.synthetic, let page = fixture.cases[name] else { throw TemperatureApplicationPage.invalid }
        return page
    }
}
