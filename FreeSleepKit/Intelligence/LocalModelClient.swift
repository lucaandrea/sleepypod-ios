import Foundation

struct LocalModelClient: Sendable {
    private let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
    func generate(_ request: ModelRequest) async throws -> ModelReply {
        let endpoint = try ConnectionEndpoint.url(request.localAddress)
        struct Body: Encodable { var model: String; var prompt: String; var system: String; var stream = false; var options: [String: Int] }
        struct Reply: Decodable { var model: String; var response: String; var done: Bool; var prompt_eval_count: Int?; var eval_count: Int? }
        var outgoing = URLRequest(url: endpoint.appending(path: "api/generate"))
        outgoing.httpMethod = "POST"; outgoing.timeoutInterval = 180
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        outgoing.httpBody = try JSONEncoder().encode(Body(model: request.model, prompt: request.prompt,
            system: request.instructions, options: ["num_predict": request.diagnostic ? 64 : 1200]))
        let (data, response) = try await session.data(for: outgoing)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw PodError.message("Your Ollama server did not accept the request. Check its address and installed model name.")
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.done else { throw PodError.message("Your local model did not finish the report.") }
        return ModelReply(text: reply.response, model: reply.model, inputTokens: reply.prompt_eval_count, outputTokens: reply.eval_count)
    }
}
