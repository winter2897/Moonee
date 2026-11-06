import Foundation

/// A skill's instruction text: the full part and an optional short part for small models.
struct SkillText: Sendable, Hashable {
    var full: String
    var short: String = ""
}

/// A skill (spec §9.4) = an instruction file per language (`Resources/Locales/<lang>/<id>.<lang>.md`, a full part and,
/// after `<!-- short -->`, a short part for small models) + the tools it may call. Only the routed skill enters the prompt.
/// User skills (`SkillStore`) carry their own text and trigger words; a user can also override a built-in's text.
/// Idea credit: adapted from the `finance` plugin of anthropics/knowledge-work-plugins (Apache-2.0); text written for Moonee.
struct Skill: Sendable, Hashable {
    let id: String
    let tools: [String]
    let job: AIJob
    /// User skills: their name. Built-ins are named in the UI.
    var title: String?
    /// User skills: words that route a message to them.
    var triggers: [String] = []
    /// User skill text, or the user's override of a built-in. Nil = the bundled file.
    var text: SkillText?

    static func == (a: Skill, b: Skill) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let transactionParser = Skill(id: "transaction-parser", tools: [], job: .parse)
    static let jarBudgeting = Skill(id: "jar-budgeting", tools: ["jarBalances", "splitIncome", "spendingSummary"], job: .advice)
    static let closeManagement = Skill(id: "close-management", tools: ["monthClose", "jarBalances", "spendingSummary"], job: .advice)
    static let spendingCoach = Skill(
        id: "spending-coach", tools: ["spendingSummary", "listTransactions", "jarBalances", "savingsPlan"], job: .quickAnswer)
    /// Outside, current info (prices, rates, news): the only skill with web access.
    /// `.advice`: in hybrid mode the cloud model (with its built-in search) answers first.
    static let marketLookup = Skill(id: "market-lookup", tools: ["marketPrice", "webSearch"], job: .advice)
    static let all = [transactionParser, jarBudgeting, closeManagement, spendingCoach, marketLookup]

    var isBuiltIn: Bool { Skill.all.contains(self) }

    func instructions(language: String, short: Bool) -> String {
        (text ?? Skill.bundled(id, language: language)).pick(short: short).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The bundled text of a built-in, split into its two parts.
    static func bundled(_ id: String, language: String) -> SkillText {
        let parts = resource(id, language: language).components(separatedBy: "<!-- short -->")
        return SkillText(full: parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                         short: parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }

    /// Moonee's voice and ground rules (spec G: "Moonee – bạn"); `short` for small models.
    static func persona(language: String, short: Bool = false) -> String {
        bundled("moonee", language: language).pick(short: short)
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
    /// Order: explicit built-in asks (close, jars) → the user's skills → outside info → questions → transactions.
    /// User skills and market lookups only take questions or non-transactions, so "mua vàng 2tr" is still logged.
    static func route(_ text: String, context: ParserContext, catalog: SkillCatalog = .builtIn) -> Skill {
        let tokens = Token.split(text)
        func asks(_ skill: Skill) -> Bool {
            [Phrase](phrases: context.lexicons.flatMap { $0.skillCues.filter { $0.skill == skill.id }.flatMap(\.words) }).contained(in: tokens)
        }
        let question = QuickParser.isQuestion(text, lexicons: context.lexicons)
        let isTransaction = { !QuickParser.parse(text, context: context).isEmpty }

        if asks(closeManagement) { return catalog.resolved(closeManagement) }
        if asks(jarBudgeting) { return catalog.resolved(jarBudgeting) }
        let user = catalog.userSkills.first { [Phrase](phrases: $0.triggers).contained(in: tokens) }
        if let user, question || !isTransaction() { return user }
        if asks(marketLookup), question || !isTransaction() { return catalog.resolved(marketLookup) }
        if question {
            let aboutJars = QuickParser.hints(in: text, context: context).jarKey != nil
                || [Phrase](phrases: context.lexicons.flatMap(\.jarWords)).contained(in: tokens)
            return catalog.resolved(aboutJars ? jarBudgeting : spendingCoach)
        }
        return catalog.resolved(isTransaction() ? transactionParser : spendingCoach)
    }
}

extension SkillText {
    func pick(short: Bool) -> String { short && !self.short.isEmpty ? self.short : full }
}
