import Foundation

struct ModelReply: Sendable {
    var text: String
    var model: String
    var inputTokens: Int?
    var outputTokens: Int?
}

struct ModelRequest: Sendable {
    var provider: IntelligenceProvider
    var model: String
    var key: String
    var localAddress: String
    var instructions: String
    var prompt: String
    var diagnostic = false
}
