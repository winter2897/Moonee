import Foundation

/// How hard a reasoning model thinks before answering (chat "effort" chip). Mapped per API in the clients;
/// a level a model does not support is never sent.
enum ReasoningEffort: String, CaseIterable, Sendable {
    case low, medium, high, higher, max

    static let `default` = ReasoningEffort.medium

    /// OpenAI `reasoning_effort` / OpenRouter `reasoning.effort` (they only know low/medium/high).
    var openAIValue: String? {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .higher, .max: nil
        }
    }

    /// Anthropic extended thinking `budget_tokens` (minimum 1024).
    var anthropicBudget: Int {
        switch self {
        case .low: 1024
        case .medium: 4096
        case .high: 10_000
        case .higher: 20_000
        case .max: 32_000
        }
    }

    /// Gemini `thinkingConfig.thinkingBudget` (2.5 Flash caps at 24,576).
    var geminiBudget: Int {
        switch self {
        case .low: 1024
        case .medium: 4096
        case .high: 8192
        case .higher: 16_384
        case .max: 24_576
        }
    }
}

/// The effort levels a BYOK model accepts; empty = no such control (the chat hides the chip).
/// DeepSeek, Custom servers, Apple on-device and local models have none.
/// OpenRouter: the model list's `supported_parameters` decide when cached, else the model name.
func supportedEfforts(provider: CloudProvider, model: String, cache: ModelCache = ModelCache()) -> [ReasoningEffort] {
    let m = model.lowercased()
    let openAIStyle: [ReasoningEffort] = [.low, .medium, .high]
    switch provider {
    case .openAI:
        return EffortModels.openAIReasoning(m) ? openAIStyle : []
    case .openRouter:
        let known = cache.load(.openRouter, baseURL: LLMSettings.defaultBaseURL)?.models.first { $0.id == model }?.reasoning
        return (known ?? EffortModels.looksLikeReasoning(m)) ? openAIStyle : []
    case .anthropic:
        return EffortModels.anthropicThinking(m) ? ReasoningEffort.allCases : []
    case .gemini:
        return EffortModels.geminiThinking(m) ? ReasoningEffort.allCases : []
    case .deepSeek, .custom:
        return []
    }
}

/// Model-name rules behind `supportedEfforts`.
/// ponytail: name heuristics; when providers expose capability flags (OpenRouter does), prefer those.
enum EffortModels {
    static func openAIReasoning(_ m: String) -> Bool {
        ["o1", "o3", "o4"].contains { m.hasPrefix($0) } || (m.hasPrefix("gpt-5") && !m.contains("chat"))
    }

    static func anthropicThinking(_ m: String) -> Bool {
        m.contains("claude") && (m.contains("3-7") || !m.contains("claude-3")) // 3.7 and every 4.x / 5.x model
    }

    static func geminiThinking(_ m: String) -> Bool {
        (m.contains("gemini-2.5") || m.contains("gemini-3")) && !m.contains("image") && !m.contains("tts")
    }

    static func looksLikeReasoning(_ m: String) -> Bool {
        if m.contains("gpt-5-chat") { return false }
        return ["/o1", "/o3", "/o4", "gpt-5", "claude-3.7", "claude-sonnet-4", "claude-opus-4", "claude-haiku-4",
                "claude-sonnet-5", "claude-opus-5", "claude-haiku-5", "gemini-2.5", "gemini-3", "deepseek-r1",
                "grok-3-mini", "grok-4", "qwen3", "thinking"].contains { m.contains($0) }
    }
}

extension LLMSettings {
    static let webSearchKey = "ai.webSearch"

    /// Web search on/off (chat composer and AI settings). On by default; it only runs when a backend is set up.
    static var webSearch: Bool {
        get { UserDefaults.standard.object(forKey: webSearchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: webSearchKey) }
    }

    static func effortKey(provider: CloudProvider, model: String) -> String { "ai.effort.\(provider.rawValue).\(model)" }

    /// Stored per provider + model; medium until the user picks.
    static func effort(provider: CloudProvider, model: String, defaults: UserDefaults = .standard) -> ReasoningEffort {
        defaults.string(forKey: effortKey(provider: provider, model: model)).flatMap(ReasoningEffort.init(rawValue:)) ?? .default
    }

    static func setEffort(_ e: ReasoningEffort, provider: CloudProvider, model: String, defaults: UserDefaults = .standard) {
        defaults.set(e.rawValue, forKey: effortKey(provider: provider, model: model))
    }

    /// Effort for the selected BYOK provider and model.
    static var effort: ReasoningEffort {
        get { effort(provider: cloudProvider, model: model(cloudProvider)) }
        set { setEffort(newValue, provider: cloudProvider, model: model(cloudProvider)) }
    }

    /// What the chat's effort chip offers right now: empty when answers don't go to a BYOK model
    /// (on-device and local modes) or the model has no effort control.
    static var supportedEffortsNow: [ReasoningEffort] {
        guard mode == .byok || mode == .hybrid, cloud(cloudProvider) != nil else { return [] }
        return supportedEfforts(provider: cloudProvider, model: model(cloudProvider))
    }
}
