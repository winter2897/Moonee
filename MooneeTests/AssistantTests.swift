import Foundation
import Testing
@testable import Moonee

struct AssistantTests {
    let ctx = Books.context

    func assistant(_ mode: AIMode = .byok, onDevice: (any LLM)? = nil, cloud: (any LLM)? = nil, language: String = "vi") -> Assistant {
        Assistant(router: AIRouter(mode: mode, onDevice: onDevice, local: nil, cloud: cloud), tools: Books.tools, language: language)
    }

    static func json(_ items: String) -> String { #"{"transactions":[\#(items)]}"# }

    // MARK: Router (spec §9.1)

    @Test func routerFollowsTheMode() {
        let apple = ScriptedLLM(small: true, replies: []), cloud = ScriptedLLM(replies: [])
        func ids(_ mode: AIMode, _ job: AIJob) -> [ObjectIdentifier] {
            AIRouter(mode: mode, onDevice: apple, local: nil, cloud: cloud).candidates(for: job).map { ObjectIdentifier($0 as AnyObject) }
        }
        let a = ObjectIdentifier(apple), c = ObjectIdentifier(cloud)
        #expect(ids(.onDevice, .advice) == [a])
        #expect(ids(.byok, .parse) == [c])
        #expect(ids(.local, .parse) == [a])               // no local model yet → Apple stands in (still on the phone)
        #expect(ids(.hybrid, .parse) == [a])              // typed transactions stay on the phone
        #expect(ids(.hybrid, .quickAnswer) == [a, c])
        #expect(ids(.hybrid, .advice) == [c, a])
        #expect(AIRouter(mode: .hybrid, onDevice: nil, local: nil, cloud: cloud).candidates(for: .parse).isEmpty)
    }

    // MARK: Parse path

    @Test func noModelUsesRules() async {
        let r = await assistant(cloud: nil).parse("phở 45k, cafe 29k", context: ctx)
        #expect(r.usedModel == false)
        #expect(r.txns.map(\.amount) == [45_000, 29_000])
    }

    @Test func modelLabelsAreKeptAmountsAreRecomputed() async {
        let model = ScriptedLLM(replies: [Self.json("""
            {"amountText":"45k","kind":"expense","category":"category.food","dateText":"hôm qua","note":"Phở bò"},
            {"amountText":"1tr2","kind":"lend","person":"anh Tuấn","note":"Cho anh Tuấn mượn"}
            """)])
        let r = await assistant(cloud: model).parse("hôm qua phở bò 45k, cho anh Tuấn mượn 1tr2", context: ctx)
        #expect(r.usedModel)
        #expect(r.txns.map(\.amount) == [45_000, 1_200_000])
        #expect(r.txns.map(\.kind) == [.expense, .lend])
        #expect(r.txns[0].note == "Phở bò")
        #expect(r.txns[1].person == "anh Tuấn")
        #expect(r.txns[1].missing == [])
        #expect(Books.cal.component(.day, from: r.txns[0].date) == 19)
        // The prompt carries only the parser skill plus the user's lists.
        let system = model.requests.first?.system ?? ""
        #expect(system.contains("transaction-parser"))
        #expect(system.contains("category.food"))
        #expect(system.contains("Vietcombank"))
        #expect(model.requests.first?.json == true)
    }

    @Test(arguments: [
        ("invented amount", AssistantTests.json(#"{"amountText":"50k","kind":"expense","note":"Phở"}"#)),
        ("missed one", AssistantTests.json(#"{"amountText":"45k","kind":"expense","note":"Phở"}"#)),
        ("bad kind", AssistantTests.json(#"{"amountText":"45k","kind":"spending","note":"Phở"},{"amountText":"29k","kind":"expense","note":"Cafe"}"#)),
        ("not JSON", "Xin lỗi, Moonee không hiểu"),
        ("empty", AssistantTests.json("")),
    ])
    func badModelOutputFallsBackToRules(_ name: String, reply: String) async {
        let r = await assistant(cloud: ScriptedLLM(replies: [reply])).parse("phở 45k, cafe 29k", context: ctx)
        #expect(r.usedModel == false, "\(name)")
        #expect(r.txns.map(\.amount) == [45_000, 29_000])
    }

    @Test func unknownLabelsAreDroppedNotTrusted() async {
        let reply = Self.json(#"{"amountText":"45k","kind":"expense","category":"category.yachts","wallet":"Techcombank","note":"Phở"}"#)
        let r = await assistant(cloud: ScriptedLLM(replies: [reply])).parse("phở 45k", context: ctx)
        #expect(r.usedModel)
        #expect(r.txns.first?.categoryKey == "category.food") // invalid key → the rule parser's guess
        #expect(r.txns.first?.wallet == nil)                   // not one of the user's wallets
    }

    /// Seen in the local-model eval: small models flip kinds the rules read from an explicit word.
    @Test(arguments: [
        ("thưởng tết 5tr", #"{"amountText":"5tr","kind":"expense","category":"category.bonus","note":"Thưởng"}"#),
        ("grab 32k", #"{"amountText":"32k","kind":"income","category":"category.otherIncome","note":"Grab"}"#),
        ("vay mẹ 3 triệu", #"{"amountText":"3 triệu","kind":"lend","person":"mẹ","note":"Vay mẹ"}"#),
    ])
    func modelCannotOverruleAnExplicitCue(text: String, item: String) async {
        let r = await assistant(cloud: ScriptedLLM(replies: [Self.json(item)])).parse(text, context: ctx)
        #expect(r.usedModel == false)
        #expect(r.txns == QuickParser.parse(text, context: ctx))
    }

    @Test func modelFillsWhatTheRulesLeftOpen() async {
        // No keyword for "highlands": the rules leave the category empty, the model's label is kept.
        let reply = Self.json(#"{"amountText":"59k","kind":"expense","category":"category.food","note":"Highlands"}"#)
        let r = await assistant(cloud: ScriptedLLM(replies: [reply])).parse("highlands 59k", context: ctx)
        #expect(r.usedModel)
        #expect(r.txns.first?.categoryKey == "category.food")
        // A keyword the rules know wins over a different model label.
        let other = Self.json(#"{"amountText":"2 lít","kind":"expense","category":"category.other","note":"Nhậu"}"#)
        let n = await assistant(cloud: ScriptedLLM(replies: [other])).parse("nhậu 2 lít", context: ctx)
        #expect(n.txns.first?.categoryKey == QuickParser.parse("nhậu 2 lít", context: ctx).first?.categoryKey)
    }

    @Test func paddedAmountlessItemsAreRejected() async {
        let reply = Self.json(#"""
            {"amountText":"120k","kind":"expense","category":"category.health","note":"Thuốc"},
            {"amountText":null,"kind":"expense","note":""}
            """#)
        let r = await assistant(cloud: ScriptedLLM(replies: [reply])).parse("mua thuốc cảm 120k", context: ctx)
        #expect(r.usedModel == false)
        #expect(r.txns.count == 1)
    }

    @Test func learnedMerchantBeatsTheModel() async {
        var c = ctx
        c.merchantRules = ["highlands": "category.custom.coffee"]
        let reply = Self.json(#"{"amountText":"59k","kind":"expense","category":"category.food","note":"Highlands"}"#)
        let r = await assistant(cloud: ScriptedLLM(replies: [reply])).parse("Highlands 59k", context: c)
        #expect(r.txns.first?.categoryKey == "category.custom.coffee")
    }

    @Test func missingAmountIsAskedNotGuessed() async {
        let reply = Self.json(#"{"amountText":null,"kind":"expense","category":"category.food","note":"Ăn trưa"}"#)
        let r = await assistant(cloud: ScriptedLLM(replies: [reply])).parse("ăn trưa với team", context: ctx)
        #expect(r.usedModel)
        #expect(r.txns.first?.amount == nil)
        #expect(r.txns.first?.missing == [.amount])
    }

    @Test func nextModelIsTriedAfterAFailure() async {
        let broken = ScriptedLLM(small: true, replies: ["{}"])
        let cloud = ScriptedLLM(replies: [Self.json(#"{"amountText":"45k","kind":"expense","note":"Phở"}"#)])
        // hybrid parse only uses on-device models, so use a router with both in the parse list.
        var a = assistant(.onDevice, onDevice: broken)
        a.router.local = cloud
        a.router.mode = .hybrid
        let r = await a.parse("xyz 45k", context: ctx) // no category cue: the small models are asked
        #expect(r.usedModel)
        #expect(broken.requests.count == 1)
    }

    // MARK: Skills and answers

    @Test(arguments: [
        ("phở 45k", "transaction-parser"), ("cho Nam mượn 2tr", "transaction-parser"),
        ("chuyển 500k sang lọ hưởng thụ", "transaction-parser"), ("ăn trưa với team", "transaction-parser"),
        ("Tháng này mình ăn uống hết bao nhiêu?", "spending-coach"), ("Còn bao nhiêu để hưởng thụ?", "jar-budgeting"),
        ("Muốn mua laptop 30tr trước Tết thì mỗi tuần cần để dành bao nhiêu?", "spending-coach"),
        ("chốt sổ tháng này", "close-management"), ("chia lương 15tr vào các lọ", "jar-budgeting"),
        ("cảm ơn Moonee", "spending-coach"), ("How much did I spend this month?", "spending-coach"),
        ("close the month", "close-management"), ("which jar is running low?", "jar-budgeting"),
    ])
    func routing(text: String, skill: String) {
        #expect(Skill.route(text, context: ctx).id == skill)
    }

    @Test func skillFilesExistInEveryLanguage() {
        for skill in Skill.all {
            for lang in Lexicon.all.map(\.language) {
                let full = skill.instructions(language: lang, short: false), short = skill.instructions(language: lang, short: true)
                #expect(full.contains(skill.id), "\(skill.id).\(lang)")
                #expect(!short.isEmpty && short.count < full.count / 2, "\(skill.id).\(lang) short")
            }
        }
        #expect(Skill.persona(language: "vi").contains("Moonee"))
        for lang in ["th", "lo"] { #expect(Skill.persona(language: lang) != Skill.persona(language: "en"), "persona \(lang)") }
        #expect(Skill.persona(language: "fr") == Skill.persona(language: "en")) // missing language → English
    }

    @Test func bigModelGetsToolsAndOneSkill() async throws {
        let model = ScriptedLLM(replies: ["Tháng này bạn chi ₫2,500,000 cho ăn uống nè!"])
        let out = await assistant(cloud: model).handle("Tháng này mình ăn uống hết bao nhiêu?", context: ctx)
        #expect(out == .answer("Tháng này bạn chi ₫2,500,000 cho ăn uống nè!", skill: "spending-coach"))
        let req = try #require(model.requests.first)
        #expect(req.tools.map(\.name) == ["spendingSummary", "listTransactions", "jarBalances", "savingsPlan"])
        #expect(req.system.contains("spending-coach"))
        #expect(!req.system.contains("jar-budgeting")) // only the routed skill is loaded
        #expect(req.system.contains("Moonee"))
    }

    @Test func smallModelGetsShortSkillAndFacts() async {
        let apple = ScriptedLLM(small: true, replies: ["Ăn uống tháng này ₫2,500,000 nha."])
        _ = await assistant(.onDevice, onDevice: apple).handle("Tháng này mình ăn uống hết bao nhiêu?", context: ctx)
        let req = apple.requests.first
        #expect(req?.tools.isEmpty == true)
        #expect(req?.messages.last?.text.contains("FACTS") == true)
        #expect(req?.messages.last?.text.contains(#""spent":"₫2,500,000""#) == true) // pre-computed for food this month
        #expect(req?.system.contains(Skill.spendingCoach.instructions(language: "vi", short: true)) == true)
    }

    @Test func noModelGivesFacts() async {
        guard case .facts(let facts, let skill) = await assistant(cloud: nil).handle("Còn bao nhiêu để hưởng thụ?", context: ctx) else {
            Issue.record("expected facts")
            return
        }
        #expect(skill == "jar-budgeting")
        #expect(facts.map(\.tool) == ["jarBalances", "spendingSummary"]) // splitIncome skipped: no amount in the question
        #expect(facts[0].json.contains("₫200,000"))
    }

    @Test func failingCloudFallsBackToFacts() async {
        let out = await assistant(cloud: ScriptedLLM(replies: [])).handle("chốt sổ tháng trước", context: ctx)
        guard case .facts(let facts, "close-management") = out else { Issue.record("expected facts"); return }
        #expect(facts.first?.json.contains(#""savingsRate":"+56%""#) == true) // "tháng trước" → lastMonth
    }

    @Test func transactionsComeBackFromHandle() async {
        let out = await assistant(cloud: nil).handle("phở 45k, cafe 29k, grab 32k", context: ctx)
        guard case .transactions(let txns, usedModel: false) = out else { Issue.record("expected transactions"); return }
        #expect(txns.count == 3)
    }

    @Test func historyIsPassedOn() async {
        let model = ScriptedLLM(replies: ["OK"])
        let history: [LLMMessage] = [.init(role: .user, text: "hi"), .init(role: .assistant, text: "Chào bạn!")]
        _ = await assistant(cloud: model).handle("cảm ơn Moonee", history: history, context: ctx)
        #expect(model.requests.first?.messages.map(\.text) == ["hi", "Chào bạn!", "cảm ơn Moonee"])
        #expect(AppleLLM.prompt(history + [.init(role: .user, text: "now")]).contains("Moonee: Chào bạn!"))
    }
}
