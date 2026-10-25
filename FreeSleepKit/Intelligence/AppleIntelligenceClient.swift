import Foundation
import FoundationModels

enum AppleIntelligenceClient {
    static var availability: String {
        guard #available(iOS 26, *) else { return "Requires iOS 26 or later and an Apple Intelligence capable device." }
        switch SystemLanguageModel.default.availability {
        case .available: return "Available · runs on this device"
        case .unavailable(.deviceNotEligible): return "This device does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in iPhone Settings."
        case .unavailable(.modelNotReady): return "Apple’s model is still downloading or preparing."
        case .unavailable: return "Apple Intelligence is currently unavailable."
        }
    }
    static var available: Bool {
        if #available(iOS 26, *) { return SystemLanguageModel.default.availability == .available }
        return false
    }
    static func generate(_ request: ModelRequest) async throws -> ModelReply {
        guard #available(iOS 26, *), available else { throw PodError.message(availability) }
        // One compact, stateless session avoids accumulating years of history in a small context window.
        let session = LanguageModelSession(instructions: request.instructions)
        do {
            let reply = try await session.respond(to: request.prompt,
                options: GenerationOptions(maximumResponseTokens: request.diagnostic ? 64 : 700))
            return ModelReply(text: reply.content, model: request.model)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PodError.message("Apple’s on-device model could not finish this request. Check that Apple Intelligence is ready, then retry with a shorter question or choose another provider. No information was sent to a cloud model.")
        }
    }
}
