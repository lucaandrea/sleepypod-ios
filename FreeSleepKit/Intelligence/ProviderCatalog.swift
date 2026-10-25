import Foundation

struct ProviderCatalog: Sendable {
    private let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
    func models(provider: IntelligenceProvider, key: String, localAddress: String) async throws -> [String] {
        if provider == .apple { return provider.models }
        guard !provider.needsKey || !key.isEmpty else { throw PodError.message("Save an API key before refreshing models.") }
        let endpoint: URL
        switch provider {
        case .openai: endpoint = URL(string: "https://api.openai.com/v1/models")!
        case .gemini: endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .anthropic: endpoint = URL(string: "https://api.anthropic.com/v1/models")!
        case .ollama: endpoint = try ConnectionEndpoint.url(localAddress).appending(path: "api/tags")
        case .apple: return provider.models
        }
        var all: [String] = []
        var cursor: String?
        for _ in 0..<20 {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            if let cursor { components.queryItems = [.init(name: provider == .gemini ? "pageToken" : "after_id", value: cursor)] }
            var request = URLRequest(url: components.url!); request.timeoutInterval = 30
            switch provider {
            case .openai: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            default: break
            }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw PodError.message("No response from the model catalog.") }
            guard (200..<300).contains(response.statusCode) else { throw PodError.message(NativeModelClient.httpError(response.statusCode)) }
            let page = try JSONDecoder().decode(Page.self, from: data)
            if provider == .gemini {
                all += (page.models ?? []).filter { $0.supportedGenerationMethods?.contains("generateContent") == true }
                    .compactMap(\.name).map { $0.replacingOccurrences(of: "models/", with: "") }
            } else { all += ((provider == .ollama ? page.models : page.data) ?? []).compactMap { $0.id ?? $0.name } }
            let next = provider == .gemini ? page.nextPageToken : (page.has_more == true ? page.last_id : nil)
            guard let next, !next.isEmpty, next != cursor else { return Array(Set(all.filter(IntelligenceProvider.validModel))).sorted() }
            cursor = next
        }
        throw PodError.message("The provider returned too many model pages. Enter the desired model ID directly.")
    }
    private struct Page: Decodable {
        struct Model: Decodable { var id: String?; var name: String?; var supportedGenerationMethods: [String]? }
        var data: [Model]?; var models: [Model]?; var nextPageToken: String?; var has_more: Bool?; var last_id: String?
    }
}
