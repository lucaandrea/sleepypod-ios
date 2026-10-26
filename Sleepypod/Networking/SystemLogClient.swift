import Foundation

protocol SystemLogClient: Sendable {
    func sources() async throws -> [LogSource]
    func page(_ query: SystemLogQuery) async throws -> SystemLogPage
}

struct CoreSystemLogClient: SystemLogClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func sources() async throws -> [LogSource] {
        struct Response: Decodable, Sendable { let sources: [LogSource] }
        let result: Response = try await client.get("system/log-sources")
        return result.sources
    }
    func page(_ query: SystemLogQuery) async throws -> SystemLogPage {
        if let validation = query.validation { throw APIError.serverError(message: validation) }
        return try await client.get("system/logs", query: query.parameters)
    }
}

struct DemoSystemLogClient: SystemLogClient {
    func sources() -> [LogSource] {
        [("sleepypod", "Core"), ("sleepypod-piezo-processor", "Piezo Processor"), ("sleepypod-sleep-detector", "Sleep Detector"), ("sleepypod-environment-monitor", "Environment Monitor")].map {
            LogSource(unit: $0.0 + ".service", name: $0.1, active: true)
        }
    }
    func page(_ query: SystemLogQuery) throws -> SystemLogPage {
        if let validation = query.validation { throw APIError.serverError(message: validation) }
        let messages: [(SystemLogLevel, String)] = [(.info, "[INFO] Simulated service ready"), (.warning, "[WARN] Simulated sensor sample is stale"), (.error, "[ERROR] Simulated sample unavailable"), (.debug, #"[DEBUG] Synthetic values {"left":72,"right":80}"#)]
        let allowed: [SystemLogLevel]
        switch query.level {
        case .error: allowed = [.error]
        case .warning: allowed = [.warning, .error]
        case .info: allowed = [.info, .warning, .error]
        default: allowed = [.info, .warning, .error, .debug]
        }
        let lines = messages.enumerated().filter { allowed.contains($0.element.0) }.map { index, item in
            "2026-10-25T18:00:0\(9 - index)-07:00 demo \(query.unit ?? "sleepypod.service")[42]: \(item.1)"
        }
        return SystemLogPage(lines: Array(lines.prefix(query.lines)), nextCursor: nil)
    }
}
