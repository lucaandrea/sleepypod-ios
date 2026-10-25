import Foundation

protocol WatchReferenceClient: Sendable {
    var destination: String { get }
    func load(side: Side, window: DateInterval) async throws -> WatchReferenceData
    func upload(file: URL, side: Side, period: WatchImportPeriod, progress: @escaping @Sendable (Double) -> Void) async throws -> WatchImportResult
}

struct CoreWatchReferenceClient: WatchReferenceClient {
    let transport: CoreRESTClient?
    init(transport: CoreRESTClient? = try? .configured()) { self.transport = transport }
    var destination: String { transport?.endpoint.absoluteString ?? "No controller configured" }
    private var client: CoreRESTClient {
        get throws { guard let transport else { throw APIError.noBaseURL }; return transport }
    }
    func load(side: Side, window: DateInterval) async throws -> WatchReferenceData {
        let client = try client
        async let heart: [ReferenceHeartRate] = records("biometrics/reference-vitals", side: side, window: window)
        async let stages: [ReferenceStage] = records("biometrics/reference-stages", side: side, window: window)
        let document: CoreAPIDocument? = try? await client.get("openapi.json")
        let extended = document?.operation("/biometrics/reference-samples", method: "get") != nil
        let (heartRows, stageRows) = try await (heart, stages)
        var result = WatchReferenceData(
            heartRate: heartRows.filter { $0.side == side.rawValue && $0.source == "apple_watch" }.compactMap(\.reading).sorted { $0.date < $1.date },
            stages: stageRows.filter { $0.side == side.rawValue && $0.source == "apple_watch" }.compactMap(\.sample).sorted { $0.start < $1.start },
            extendedMetrics: extended)
        if extended {
            async let breathing: [ReferenceMetricSample] = records("biometrics/reference-samples", side: side, window: window, metric: "breathing_rate")
            async let hrv: [ReferenceMetricSample] = records("biometrics/reference-samples", side: side, window: window, metric: "hrv_sdnn")
            result.breathing = try await breathing.compactMap(\.reading).sorted { $0.date < $1.date }
            result.hrv = try await hrv.compactMap(\.reading).sorted { $0.date < $1.date }
        }
        return result
    }
    // The REST routes cap responses; recursively split ranges rather than silently losing old samples.
    private func records<Record: Decodable & Identifiable & Sendable>(_ path: String, side: Side, window: DateInterval, metric: String? = nil) async throws -> [Record] where Record.ID: Hashable & Sendable {
        let client = try client
        return try await MetricRangeLoader.load(start: window.start, end: window.end, limit: 20000) { start, end in
            var query = ["side": side.rawValue, "startDate": start.ISO8601Format(), "endDate": end.ISO8601Format(), "limit": "20000"]
            if let metric { query["metric"] = metric }
            return try await client.get(path, query: query)
        }
    }
    func upload(file: URL, side: Side, period: WatchImportPeriod, progress: @escaping @Sendable (Double) -> Void) async throws -> WatchImportResult {
        _ = try WatchExportFile.validate(file)
        let client = try client
        var request = try client.request("biometrics/watch-upload", method: "POST", query: ["side": side.rawValue, "days": String(period.rawValue)])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 41 * 60
        let delegate = WatchUploadProgress(progress: progress)
        let (data, response) = try await client.session.upload(for: request, fromFile: file, delegate: delegate)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse(statusCode: 0) }
        guard (200..<300).contains(response.statusCode) else {
            struct Failure: Decodable { let error: String?; let message: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw APIError.serverError(message: String((failure?.error ?? failure?.message ?? "Import failed (HTTP \(response.statusCode)).").prefix(500)))
        }
        return try JSONDecoder().decode(WatchImportResult.self, from: data)
    }
}

private final class WatchUploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

struct DemoWatchReferenceClient: WatchReferenceClient {
    var destination: String { "Demo · no file is sent" }
    func load(side: Side, window: DateInterval) async throws -> WatchReferenceData {
        var result = WatchReferenceData(extendedMetrics: true)
        for index in 0..<Int(window.duration / 900) {
            let date = window.start.addingTimeInterval(Double(index) * 900)
            result.heartRate.append(.init(date: date, value: 58 + sin(Double(index) / 9) * 8))
            if index % 4 == 0 {
                result.breathing.append(.init(date: date, value: 14 + sin(Double(index) / 15)))
                result.hrv.append(.init(date: date, value: 39 + cos(Double(index) / 20) * 14))
            }
            let hour = Calendar.current.component(.hour, from: date)
            if hour >= 23 || hour < 7 { result.stages.append(.init(start: date, end: date.addingTimeInterval(900), stage: index % 5 == 0 ? .deep : .light)) }
        }
        return result
    }
    func upload(file: URL, side: Side, period: WatchImportPeriod, progress: @escaping @Sendable (Double) -> Void) async throws -> WatchImportResult {
        throw APIError.serverError(message: "Connect to your controller to import Health exports. Demo mode never uploads files.")
    }
}
