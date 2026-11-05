import Foundation

/// A skill (spec §9.4) = an instruction file per language (`Resources/Locales/<lang>/<id>.<lang>.md`, a full part and,
/// after `<!-- short -->`, a short part for small models) + the tools it may call. Only the routed skill enters the prompt.
/// Idea credit: adapted from the `finance` plugin of anthropics/knowledge-work-plugins (Apache-2.0); text written for Moonee.
struct Skill: Sendable, Hashable {
    let id: String
    let tools: [String]
    let job: AIJob

    static let transactionParser = Skill(id: "transaction-parser", tools: [], job: .parse)
    static let jarBudgeting = Skill(id: "jar-budgeting", tools: ["jarBalances", "splitIncome", "spendingSummary"], job: .advice)
    static let closeManagement = Skill(id: "close-management", tools: ["monthClose", "jarBalances", "spendingSummary"], job: .advice)
    static let spendingCoach = Skill(
        id: "spending-coach", tools: ["spendingSummary", "listTransactions", "jarBalances", "savingsPlan"], job: .quickAnswer)
    static let all = [transactionParser, jarBudgeting, closeManagement, spendingCoach]

    func instructions(language: String, short: Bool) -> String {
        let text = Skill.resource(id, language: language)
        let parts = text.components(separatedBy: "<!-- short -->")
        return (short && parts.count > 1 ? parts[1] : parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Moonee's voice and ground rules (spec G: "Moonee – bạn").
    static func persona(language: String) -> String {
        resource("moonee", language: language).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<name>.<lang>.md` from the app bundle, falling back to English.
    static func resource(_ name: String, language: String) -> String {
        for lang in [language, "en"] {
            if let url = Bundle.main.url(forResource: "\(name).\(lang)", withExtension: "md"),
               let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return ""
    }

    /// Picks the skill a message needs (intent first, then a parse check), so only that one is loaded.
    static func route(_ text: String, context: ParserContext) -> Skill {
        let tokens = Token.split(text)
        func asks(_ skill: Skill) -> Bool {
            [Phrase](phrases: context.lexicons.flatMap { $0.skillCues.filter { $0.skill == skill.id }.flatMap(\.words) }).contained(in: tokens)
        }
        if asks(closeManagement) { return closeManagement }
        if asks(jarBudgeting) { return jarBudgeting }
        if QuickParser.isQuestion(text, lexicons: context.lexicons) {
            let aboutJars = QuickParser.hints(in: text, context: context).jarKey != nil
                || [Phrase](phrases: context.lexicons.flatMap(\.jarWords)).contained(in: tokens)
            return aboutJars ? jarBudgeting : spendingCoach
        }
        return QuickParser.parse(text, context: context).isEmpty ? spendingCoach : transactionParser
    }
}
