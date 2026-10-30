#if DEBUG
import SwiftUI

/// An offline transport fixture exercises the real recovery view without contacting any controller.
struct ConnectionRecoveryPreview: View {
    @State private var device: DeviceManager
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionPreviewProtocol.self]
        let client = SleepypodCoreClient(session: URLSession(configuration: configuration), baseURL: URL(string: "https://connection-preview.invalid")!)
        _device = State(initialValue: DeviceManager(api: client))
    }
    var body: some View {
        NavigationStack { DisconnectedTabView(tab: "Temp") }
            .environment(device)
            .task { await device.fetchStatus() }
            .onDisappear { device.stopPolling() }
    }
}

private class ConnectionPreviewProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET", url.path == "/api/trpc/device.getStatus" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"json":{"message":"Access rejected"}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
