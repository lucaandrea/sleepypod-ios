import Foundation

struct CoachUsage: Codable, Sendable, Equatable {
    struct Provider: Codable, Sendable, Equatable, Identifiable {
        var provider: String; var models: [String]
        var attempts: Int; var completed: Int; var failed: Int; var unresolved: Int; var pending: Int
        var tokensReportedFor: Int; var inputTokens: Int; var outputTokens: Int; var totalTokens: Int
        var averageResponseMilliseconds: Int?
        var id: String { provider }
        var title: String { ["openai": "OpenAI", "gemini": "Gemini", "anthropic": "Anthropic", "ollama": "Ollama"][provider] ?? provider }
    }
    var version: Int; var period: String; var resetsAt: String; var monthlyLimit: Int; var revision: Int; var remaining: Int
    var attempts: Int; var completed: Int; var failed: Int; var unresolved: Int; var pending: Int
    var tokensReportedFor: Int; var inputTokens: Int; var outputTokens: Int; var totalTokens: Int
    var averageResponseMilliseconds: Int?
    var providers: [Provider]
}
