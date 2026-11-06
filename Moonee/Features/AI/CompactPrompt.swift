import Foundation

/// The low-token prompt every small model gets (`LLM.isSmall`: Apple on-device and local MLX models).
/// Apple's window is 4096 tokens on iOS 26 for instructions + prompt + answer; Vietnamese runs ~3 characters a token
/// (measured with `SystemLanguageModel.tokenCount`), so the whole request stays under ~1,800 tokens:
/// short persona + short skill + clipped FACTS, the last few turns clipped, the message clipped.
/// `tight` (the retry after a context overflow) drops the history and halves the facts.
enum CompactPrompt {
    static let factsChars = 1_500
    static let turns = 4
    static let turnChars = 240
    static let textChars = 600
    static let customChars = 300

    static func request(persona: String, skill: String, facts: [Assistant.ToolResult]?, customPrompt: String = "",
                        history: [LLMMessage], text: String, tight: Bool = false) -> LLMRequest {
        var system = persona + "\n\n" + skill
        if !customPrompt.isEmpty { system += "\n\nThe user's own instructions:\n" + clip(customPrompt, customChars) }
        if let facts {
            system += "\n\nFACTS (computed by the app; use only these numbers):\n" + self.facts(facts, limit: tight ? factsChars / 2 : factsChars)
        }
        let past = tight ? [] : history.suffix(turns).map { LLMMessage(role: $0.role, text: clip($0.text, turnChars)) }
        return LLMRequest(system: system, messages: past + [.init(role: .user, text: clip(text, textChars))])
    }

    /// One line per tool. Search results are cut to 3 short hits; other JSON is clipped to its share of `limit`.
    static func facts(_ facts: [Assistant.ToolResult], limit: Int = factsChars) -> String {
        guard !facts.isEmpty else { return "(none)" }
        let share = limit / facts.count
        return facts.map { f in
            var json = f.json
            if f.tool == "webSearch", var r = try? JSONDecoder().decode(SearchResult.self, from: Data(json.utf8)) {
                r.results = r.results.prefix(3).map { var h = $0; h.text = clip(h.text, 160); return h }
                r.summary = r.summary.map { clip($0, 300) }
                json = (try? AITool.encode(r)) ?? json
            }
            return "\(f.tool): " + clip(json, share)
        }.joined(separator: "\n")
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }
}
