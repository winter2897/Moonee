import Foundation

/// What a model is used for; the router picks models per job (spec §9.1, §9.3).
enum AIJob: Sendable { case parse, quickAnswer, advice }

/// Which models to try, in order, for a job.
struct AIRouter: Sendable {
    var mode: AIMode
    /// Apple Foundation Models, when the device has Apple Intelligence.
    var onDevice: (any LLM)?
    /// Downloaded open model run with MLX (`LocalLLM`).
    var local: (any LLM)?
    /// BYOK cloud model with a key.
    var cloud: (any LLM)?

    /// Empty = no model: rule parser and plain numbers only (spec §9.1 fallback).
    func candidates(for job: AIJob) -> [any LLM] {
        let list: [(any LLM)?] = switch mode {
        case .onDevice: [onDevice]
        case .local: [local]
        case .byok: [cloud]
        case .hybrid: switch job {
            case .parse: [onDevice, local] // hybrid keeps typed transactions on the phone
            case .quickAnswer: [onDevice, local, cloud]
            case .advice: [cloud, onDevice, local]
            }
        }
        return list.compactMap { $0 }
    }
}

/// The engine the chat screen calls. No UI; never throws: every failure falls back to the rule parser
/// or to the plain numbers the tools computed.
///
///     let assistant = Assistant(router: LLMSettings.router(), tools: MooneeTools(ledger: store))
///     switch await assistant.handle(text, history: chat, context: parserContext) { … }
struct Assistant: Sendable {
    var router: AIRouter
    var tools: MooneeTools
    /// Moonee answers in the UI language (spec §10.4); input may be any language.
    var language = Assistant.uiLanguage
    /// Skill ids the user switched off in AI settings: no model runs for them (rules / plain numbers instead).
    var skillsOff = LLMSettings.skillsOff
    /// The user's own instructions (Settings → Advanced), added to every answer prompt.
    var customPrompt = LLMSettings.customPrompt
    /// User skills and overrides of built-in text; pass `SkillCatalog(context)` to use them.
    var catalog = SkillCatalog.builtIn
    /// Thinking effort for answers (the chat chip); clients drop levels the model can't take. Parsing never thinks.
    var effort: ReasoningEffort? = LLMSettings.effort

    enum Output: Sendable, Equatable {
        /// Save right away and show cards (spec §3.2); ask for `missing` fields first. `usedModel` false = rule parser.
        case transactions([ParsedTxn], usedModel: Bool)
        /// Moonee's reply, from the skill `skill`, with the web sources it was given (market lookups; else empty).
        case answer(String, skill: String, sources: [WebSource] = [])
        /// No model could answer: the skill's tool results (JSON per tool) for the screen to show as numbers.
        case facts([ToolResult], skill: String)
    }

    struct ToolResult: Sendable, Equatable {
        var tool: String
        var json: String
    }

    static var uiLanguage: String {
        let code = Bundle.main.preferredLocalizations.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? $0 }
        return Lexicon.all.map(\.language).first { $0 == code } ?? "en"
    }

    func handle(_ text: String, history: [LLMMessage] = [], context: ParserContext) async -> Output {
        let skill = Skill.route(text, context: context, catalog: catalog)
        guard skill != .transactionParser else {
            let r = await parse(text, context: context)
            return .transactions(r.txns, usedModel: r.usedModel)
        }
        return await answer(text, skill: skill, history: history, context: context)
    }

    /// Reads transactions with the first model that gives valid output, else the rule parser.
    func parse(_ text: String, context: ParserContext) async -> (txns: [ParsedTxn], usedModel: Bool) {
        let rules = QuickParser.parse(text, context: context)
        for model in skillsOff.contains(Skill.transactionParser.id) ? [] : router.candidates(for: .parse) {
            let instructions = parseInstructions(short: model.isSmall, context: context)
            if let items = try? await model.extractTransactions(instructions: instructions, text: text),
               let txns = TransactionExtractor.validate(items, text: text, rules: rules, context: context) {
                return (txns, true)
            }
        }
        return (rules, false)
    }

    /// Answers with a skill. Big models call the skill's tools; small ones get the tool results in the prompt.
    func answer(_ text: String, skill: Skill, history: [LLMMessage] = [], context: ParserContext) async -> Output {
        let log = SourceLog()
        let skillTools = tools.named(skill.tools).map(log.wrap)
        var facts: [ToolResult]?
        func prefetched() async -> [ToolResult] {
            if let facts { return facts }
            let r = await prefetch(skillTools, text: text, context: context)
            facts = r
            return r
        }
        for model in skillsOff.contains(skill.id) ? [] : router.candidates(for: skill.job) {
            var request = LLMRequest(
                system: Skill.persona(language: language) + "\n\n" + skill.instructions(language: language, short: model.isSmall),
                messages: history + [.init(role: .user, text: text)])
            if !customPrompt.isEmpty { request.system += "\n\nThe user's own instructions:\n" + customPrompt }
            request.effort = effort
            if model.isSmall {
                let lines = await prefetched().map { "\($0.tool): \($0.json)" }.joined(separator: "\n")
                request.system += "\n\nFACTS (computed by the app; use only these numbers):\n" + lines
            } else {
                request.tools = skillTools
            }
            if let reply = try? await model.respond(request), !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .answer(reply, skill: skill.id, sources: log.sources)
            }
        }
        return .facts(await prefetched(), skill: skill.id)
    }

    /// Runs every tool of the skill with what the question says (period, category, jar, amount). Failing tools are skipped.
    func prefetch(_ tools: [AITool], text: String, context: ParserContext) async -> [ToolResult] {
        let h = QuickParser.hints(in: text, context: context)
        var args = ToolArgs()
        args.period = h.period.flatMap(LedgerPeriod.init(rawValue:))
        args.month = args.period == .lastMonth ? .lastMonth : nil
        args.categoryKey = h.categoryKey
        args.jarKey = h.jarKey
        args.amountText = text // tools read the amount from the user's words themselves
        args.targetText = text
        args.query = text
        args.symbol = MarketPrices.symbol(in: text)
        let data = (try? JSONEncoder().encode(args)) ?? Data("{}".utf8)
        var out: [ToolResult] = []
        for tool in tools {
            if let json = try? await tool.run(data) { out.append(.init(tool: tool.name, json: json)) }
        }
        return out
    }

    private func parseInstructions(short: Bool, context: ParserContext) -> String {
        let categories = DefaultKeys.categories + context.categories.values
        let jars = DefaultKeys.jars + context.jars.values
        return catalog.resolved(.transactionParser).instructions(language: language, short: short) + """


            Category keys: \(Array(Set(categories)).sorted().joined(separator: ", "))
            Jar keys: \(Array(Set(jars)).sorted().joined(separator: ", "))
            Wallets: \(context.wallets.joined(separator: ", "))
            """
    }
}

/// Turns a model's reading into transactions, trusting it only for labels: amounts and dates are recomputed by
/// `QuickParser` from the words the model quoted, and must agree with the rule parser. Where the rules saw an explicit
/// cue (a kind word, a category keyword) they win; the model fills the gaps ("highlands 59k"). Any doubt → nil
/// (caller falls back). The local-model eval showed small models flipping kinds and padding the list.
enum TransactionExtractor {
    static func validate(_ items: [AIParsedTxn], text: String, rules: [ParsedTxn], context: ParserContext) -> [ParsedTxn]? {
        guard !items.isEmpty else { return nil }
        let haystack = fold(text)
        func quoted(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.lowercased() != "null" else { return nil }
            return haystack.contains(fold(s)) ? s : nil
        }

        var unpaired = rules
        var out: [ParsedTxn] = []
        for item in items {
            guard let kind = EntryKind(rawValue: item.kind) else { return nil }
            var amount: (amount: Int, currency: String)?
            if let a = item.amountText, !a.isEmpty, a.lowercased() != "null" {
                guard quoted(a) != nil, let v = QuickParser.amount(in: a, context: context) else { return nil } // invented money
                amount = v
            }
            let pair = unpaired.firstIndex { $0.amount == amount?.amount }.map { unpaired.remove(at: $0) }
            // "thưởng 5tr" is income and "grab 32k" an expense whatever a small model says.
            if let pair, pair.kind != kind, pair.kind != .expense || pair.categoryKey != nil { return nil }

            var t = ParsedTxn(
                amount: amount?.amount, currency: amount?.currency ?? context.currency, kind: kind,
                date: quoted(item.dateText).flatMap { QuickParser.date(in: $0, context: context) } ?? pair?.date ?? rules.first?.date ?? context.now,
                note: item.note.trimmingCharacters(in: .whitespacesAndNewlines))
            if t.note.isEmpty { t.note = pair?.note ?? "" }
            if kind == .expense || kind == .income {
                let allowed = Set((kind == .income ? DefaultKeys.incomeCategories : DefaultKeys.expenseCategories)
                    + context.categories.values + context.merchantRules.values)
                let learned = context.merchantRules.first { haystack.contains(fold($0.key)) }?.value // user's own edits win
                t.categoryKey = learned ?? pair?.categoryKey ?? item.category.flatMap { allowed.contains($0) ? $0 : nil }
            }
            t.wallet = wallet(item.wallet, context) ?? pair?.wallet
            t.toWallet = wallet(item.toWallet, context) ?? pair?.toWallet
            if kind == .jarTransfer {
                t.jar = jar(item.jar, context) ?? pair?.jar
                t.toJar = jar(item.toJar, context) ?? pair?.toJar
            }
            if [.lend, .borrow, .repay].contains(kind) { t.person = quoted(item.person) ?? pair?.person }
            t.missing = ParsedTxn.missing(of: t)
            out.append(t)
        }
        // The rule parser reads money reliably: the model must find exactly the same amounts, and no extra
        // amount-less items (small models pad the list).
        let ruleAmounts = rules.compactMap(\.amount).sorted()
        guard ruleAmounts.isEmpty || (out.allSatisfy { $0.amount != nil } && ruleAmounts == out.compactMap(\.amount).sorted())
        else { return nil }
        return out
    }

    private static func fold(_ s: String) -> String { Token.fold(s.lowercased().precomposedStringWithCanonicalMapping) }

    private static func wallet(_ name: String?, _ c: ParserContext) -> String? {
        guard let name else { return nil }
        return c.wallets.first { fold($0) == fold(name) }
    }

    private static func jar(_ value: String?, _ c: ParserContext) -> String? {
        guard let value else { return nil }
        if DefaultKeys.jars.contains(value) || c.jars.values.contains(value) { return value }
        return c.jars.first { fold($0.key) == fold(value) }?.value
    }
}
