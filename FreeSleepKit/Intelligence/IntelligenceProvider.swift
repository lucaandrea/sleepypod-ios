import Foundation

enum IntelligenceProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple, openai, gemini, anthropic, ollama
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple · on this iPhone"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .anthropic: "Anthropic Claude"
        case .ollama: "Local server · Ollama / Gemma"
        }
    }
    var needsKey: Bool { self != .apple && self != .ollama }
    var leavesDevice: Bool { self != .apple }
    // These are starting choices, not promises of access. Refresh the provider's catalog or enter an ID.
    var models: [String] {
        switch self {
        case .apple: ["Apple Foundation Models"]
        case .openai: ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna"]
        case .gemini: ["gemini-4-argon", "gemini-3.8-flash", "gemini-3.5-flash-lite"]
        case .anthropic: ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5"]
        case .ollama: ["gemma3:4b"]
        }
    }
    static func validModel(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/".contains($0)) }
            && !value.contains("..") && !value.contains("//") && !value.hasPrefix("/")
    }
}
