import Foundation

/// Read-only schema discovery also works when a controller has no saved curves or alarms.
struct CoreAPIDocument: Decodable, Sendable {
    struct Operation: Decodable, Sendable {
        struct Body: Decodable, Sendable {
            struct Media: Decodable, Sendable { var schema: Schema? }
            var content: [String: Media]?
        }
        var requestBody: Body?
        var responses: [String: Body]?
    }
    struct Schema: Decodable, Sendable {
        var properties: [String: Schema]?
        var allOf: [Schema]?
        var reference: String?
        enum CodingKeys: String, CodingKey { case properties, allOf; case reference = "$ref" }
    }
    struct Components: Decodable, Sendable { var schemas: [String: Schema]? }
    var paths: [String: [String: Operation]]
    var components: Components?
    func operation(_ path: String, method: String) -> Operation? {
        (paths[path] ?? paths["/api" + path])?[method.lowercased()]
    }
    func accepts(_ field: String, path: String, method: String) -> Bool {
        guard let schema = operation(path, method: method)?.requestBody?.content?["application/json"]?.schema else { return false }
        return contains(field, schema: schema, depth: 0)
    }
    func returns(_ field: String, path: String, method: String) -> Bool {
        guard let schema = operation(path, method: method)?.responses?["200"]?.content?["application/json"]?.schema else { return false }
        return contains(field, schema: schema, depth: 0)
    }
    private func contains(_ field: String, schema: Schema, depth: Int) -> Bool {
        guard depth < 8 else { return false }
        if schema.properties?[field] != nil { return true }
        if let reference = schema.reference, reference.hasPrefix("#/components/schemas/"),
           let target = components?.schemas?[String(reference.dropFirst("#/components/schemas/".count))], contains(field, schema: target, depth: depth + 1) { return true }
        return schema.allOf?.contains { contains(field, schema: $0, depth: depth + 1) } ?? false
    }
}

protocol CurveClient: Sendable {
    func library() async throws -> CurveLibrarySnapshot
    func put(_ input: CurvePut, assignments: Bool) async throws -> CurveChange
    func delete(_ curve: PodCurve) async throws
    func active(_ side: Side) async throws -> RunOnceSession?
    func start(side: Side, points: [RunOnceSetPoint], wake: String) async throws -> RunOnceStartResponse
    func cancel(_ side: Side) async throws
}

struct CoreCurveClient: CurveClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private func client() throws -> CoreRESTClient {
        guard let transport else { throw APIError.noBaseURL }
        return transport
    }
    func library() async throws -> CurveLibrarySnapshot {
        let api = try client()
        let curves: [PodCurve] = try await api.get("curve-templates")
        if curves.contains(where: { $0.days != nil && $0.active != nil }) { return CurveLibrarySnapshot(curves: curves, supportsAssignments: true) }
        let schema: CoreAPIDocument? = try? await api.get("openapi.json")
        return CurveLibrarySnapshot(curves: curves, supportsAssignments: schema?.operation("/curve-templates", method: "put") != nil)
    }
    func put(_ input: CurvePut, assignments: Bool) async throws -> CurveChange {
        if assignments { return try await client().put("curve-templates", body: input, returning: CurveChange.self) }
        struct Legacy: Encodable, Sendable { var name: String; var bedtime: String; var wake: String; var points: [String: Double]; var notes: String }
        let curve = try await client().post("curve-templates", body: Legacy(name: input.name, bedtime: input.bedtime, wake: input.wake, points: input.points, notes: input.notes), returning: PodCurve.self)
        return CurveChange(curve: curve, moved: [])
    }
    func delete(_ curve: PodCurve) async throws { try await client().delete("curve-templates", query: ["name": curve.name]) }
    func active(_ side: Side) async throws -> RunOnceSession? { try await client().get("run-once/active", query: ["side": side.rawValue]) }
    func start(side: Side, points: [RunOnceSetPoint], wake: String) async throws -> RunOnceStartResponse {
        struct Start: Encodable, Sendable { var side: Side; var setPoints: [RunOnceSetPoint]; var wakeTime: String }
        return try await client().post("run-once/start", body: Start(side: side, setPoints: points, wakeTime: wake), returning: RunOnceStartResponse.self)
    }
    func cancel(_ side: Side) async throws {
        struct Cancel: Encodable, Sendable { var side: Side }
        try await client().post("run-once/cancel", body: Cancel(side: side))
    }
}

actor DemoCurveClient: CurveClient {
    private var curves: [PodCurve] = [
        PodCurve(id: 1, name: "Weeknight", bedtime: "22:00", wake: "07:00", points: ["22:00": 76, "23:30": 70, "04:00": 72, "07:00": 80], notes: "A cool start with a gentle warm wake.", endAction: .turnOff, days: CurveDays(left: Array(DayOfWeek.weekdays.prefix(5)), right: DayOfWeek.weekdays), active: true),
        PodCurve(id: 2, name: "Weekend", bedtime: "23:00", wake: "08:00", points: ["23:00": 78, "01:00": 72, "06:00": 75, "08:00": 82], notes: "", endAction: .maintain, days: CurveDays(left: [.saturday, .sunday]), active: false)
    ]
    private var sessions: [Side: RunOnceSession] = [:]
    private var nextID = 100
    private let scenario: String
    init(scenario: String = DebugRoute.curveScenario) {
        self.scenario = scenario
        if scenario == "legacy" {
            for index in curves.indices { curves[index].days = nil; curves[index].active = nil }
        }
    }
    func library() async throws -> CurveLibrarySnapshot {
        if scenario == "offline" { throw URLError(.notConnectedToInternet) }
        return CurveLibrarySnapshot(curves: curves, supportsAssignments: scenario != "legacy")
    }
    func put(_ input: CurvePut, assignments: Bool) async throws -> CurveChange {
        guard !curves.contains(where: { $0.name == input.name && $0.id != input.id }) else { throw APIError.serverError(message: "Another curve already has that name.") }
        var draft = CurveDraft(); draft.original = curves.first { $0.id == input.id }; draft.days = input.days; draft.active = input.active
        let moved = CurveMove.preview(draft, among: curves)
        for index in curves.indices where curves[index].id != input.id && curves[index].active == true && input.active {
            for side in Side.allCases { curves[index].days?[side].removeAll { input.days[side].contains($0) } }
            if curves[index].days?.isEmpty == true { curves[index].active = false }
        }
        let curve = PodCurve(id: input.id ?? nextID, name: input.name, bedtime: input.bedtime, wake: input.wake, points: input.points,
                             notes: input.notes, endAction: input.endAction, days: assignments ? input.days : nil, active: assignments ? input.active && !input.days.isEmpty : nil)
        if input.id == nil { nextID += 1 }
        curves.removeAll { $0.id == curve.id }; curves.append(curve)
        return CurveChange(curve: curve, moved: moved)
    }
    func delete(_ curve: PodCurve) async throws { curves.removeAll { $0.id == curve.id } }
    func active(_ side: Side) async throws -> RunOnceSession? {
        guard let session = sessions[side], session.expiresAtDate > .now else { return nil }; return session
    }
    func start(side: Side, points: [RunOnceSetPoint], wake: String) async throws -> RunOnceStartResponse {
        let now = Int(Date().timeIntervalSince1970); let expiry = now + 8 * 3600
        sessions[side] = RunOnceSession(id: nextID, side: side.rawValue, setPoints: points, wakeTime: wake, startedAt: now, expiresAt: expiry, status: "active")
        nextID += 1
        if scenario == "uncertain-start" { throw URLError(.timedOut) }
        return RunOnceStartResponse(sessionId: nextID - 1, expiresAt: expiry)
    }
    func cancel(_ side: Side) async throws { sessions.removeValue(forKey: side) }
}
