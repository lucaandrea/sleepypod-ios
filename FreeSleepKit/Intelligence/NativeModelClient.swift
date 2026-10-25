import Foundation
import AIProxy

struct NativeModelClient: Sendable {
    static func configureSDK() {
        AIProxy.configure(logLevel: .critical, printRequestBodies: false, printResponseBodies: false,
            resolveDNSOverTLS: false, useStableID: false)
    }
    func generate(_ request: ModelRequest) async throws -> ModelReply {
        guard request.provider == .apple || IntelligenceProvider.validModel(request.model) else {
            throw PodError.message("Choose a model or enter its API model ID.")
        }
        guard !request.provider.needsKey || !request.key.isEmpty else { throw PodError.message("Save this provider’s API key first.") }
        try Task.checkCancellation()
        do {
            let reply: ModelReply
            switch request.provider {
            case .apple: reply = try await AppleIntelligenceClient.generate(request)
            case .openai: reply = try await openAI(request)
            case .gemini: reply = try await gemini(request)
            case .anthropic: reply = try await anthropic(request)
            case .ollama: reply = try await LocalModelClient().generate(request)
            }
            try Task.checkCancellation()
            guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reply.text.count <= 40_000 else {
                throw PodError.message("The model returned no usable report. Try a different model.")
            }
            return reply
        } catch let error as AIProxyError {
            if case .unsuccessfulRequest(let code, _) = error { throw PodError.message(Self.httpError(code)) }
            throw PodError.message("The model SDK could not complete this request. No bed controls changed.")
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw PodError.message(error.code == .timedOut ? "The model timed out. You can retry or choose another model." : "The model could not be reached. Check your network connection.")
        }
    }
    static func httpError(_ code: Int) -> String {
        switch code {
        case 401, 403: "The provider rejected the key or model access. Check your API key and account permissions."
        case 404: "This model is unavailable to your key. Refresh the model list or enter another model ID."
        case 429: "The provider’s rate or billing limit was reached. Check your API account before retrying."
        default: "The provider could not complete the request (HTTP \(code)). No automatic retry was made."
        }
    }
    private func openAI(_ request: ModelRequest) async throws -> ModelReply {
        let service = AIProxy.openAIDirectService(unprotectedAPIKey: request.key)
        let body = OpenAICreateResponseRequestBody(input: .text(request.prompt), instructions: request.instructions,
            maxOutputTokens: request.diagnostic ? 512 : 8000, model: request.model, store: false)
        let response = try await service.createResponse(requestBody: body, secondsToWait: 180)
        guard response.status == .completed else { throw PodError.message("OpenAI did not finish the report. Try again with a different model.") }
        return ModelReply(text: response.outputText, model: response.model ?? request.model,
            inputTokens: response.usage?.inputTokens, outputTokens: response.usage?.outputTokens)
    }
    private func gemini(_ request: ModelRequest) async throws -> ModelReply {
        let service = AIProxy.geminiDirectService(unprotectedAPIKey: request.key)
        let body = GeminiGenerateContentRequestBody(contents: [.init(parts: [.text(request.prompt)], role: "user")],
            generationConfig: .init(maxOutputTokens: request.diagnostic ? 512 : 8000),
            systemInstruction: .init(parts: [.text(request.instructions)]))
        let response = try await service.generateContentRequest(body: body, model: request.model, secondsToWait: 180)
        guard let candidate = response.candidates?.first, candidate.finishReason == "STOP" else {
            throw PodError.message("Gemini blocked or did not finish the report. Try another model or a shorter question.")
        }
        let content = (candidate.content?.parts ?? []).compactMap { part -> String? in
            if case .text(let text) = part { return text }; return nil
        }.joined(separator: "\n")
        return ModelReply(text: content, model: request.model, inputTokens: response.usageMetadata?.promptTokenCount,
            outputTokens: response.usageMetadata?.candidatesTokenCount)
    }
    private func anthropic(_ request: ModelRequest) async throws -> ModelReply {
        let service = AIProxy.anthropicDirectService(unprotectedAPIKey: request.key)
        let body = AnthropicMessageRequestBody(maxTokens: request.diagnostic ? 512 : 8000,
            messages: [.init(content: .text(request.prompt), role: .user)], model: request.model, system: .text(request.instructions))
        let response = try await service.messageRequest(body: body, secondsToWait: 180)
        guard response.stopReason == .endTurn else { throw PodError.message("Claude did not finish the report. Try a different model.") }
        let content = response.content.compactMap { block -> String? in
            if case .textBlock(let text) = block { return text.text }; return nil
        }.joined(separator: "\n")
        return ModelReply(text: content, model: response.model,
            inputTokens: response.usage.inputTokens, outputTokens: response.usage.outputTokens)
    }
}
