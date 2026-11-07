import Foundation
import SwiftData
import Testing
@testable import Moonee

/// Category limits inside jars (spec P1-1): spent vs limit, the over-the-jar warning, reminders and chat.
@MainActor struct CategoryLimitTests {
    typealias Line = BudgetFacts.CategoryLine
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func at(_ m: Int, _ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))! }

    var vnd: ParserContext {
        var c = ParserContext()
        (c.currency, c.calendar) = ("VND", cal)
        return c
    }

    @Test func spentAgainstLimit() {
        #expect(Line(key: "f", name: "Food", limit: nil, spent: 5_000_000).level == nil)
        #expect(Line(key: "f", name: "Food", limit: nil, spent: 5_000_000).left == nil)
        #expect(Line(key: "f", name: "Food", limit: 3_000_000, spent: 2_000_000).level == .normal)
        #expect(Line(key: "f", name: "Food", limit: 3_000_000, spent: 2_400_000).level == .warning) // 80%
        #expect(Line(key: "f", name: "Food", limit: 3_000_000, spent: 3_000_000).level == .warning) // at the limit, not past it
        let over = Line(key: "f", name: "Food", limit: 3_000_000, spent: 3_200_000)
        #expect(over.level == .over && over.left == -200_000)
    }

    @Test func limitsOverTheJar() {
        var jar = BudgetFacts.JarLine(key: "jar.essentials", name: "Essentials", percent: 55, start: 1_000_000, added: 2_000_000, spent: 0, balance: 3_000_000)
        jar.categories = [Line(key: "a", name: "Food", limit: 2_000_000, spent: 0), Line(key: "b", name: "Transport", limit: nil, spent: 0)]
        #expect(jar.limits == 2_000_000 && !jar.limitsOverBudget)
        jar.categories.append(Line(key: "c", name: "Housing", limit: 1_500_000, spent: 0))
        #expect(jar.limits == 3_500_000 && jar.limitsOverBudget) // 3.5tr of limits, the jar has 3tr this month
        jar.added = -1_000_000 // an empty jar: any limit is more than it has
        jar.categories = [Line(key: "a", name: "Food", limit: 1, spent: 0)]
        #expect(jar.limitsOverBudget)
    }

    @Test func budgetFactsCarryCategoryLines() throws {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        Seed.ifNeeded(context)
        let categories = try context.fetch(FetchDescriptor<Moonee.Category>())
        let food = try #require(categories.first { $0.key == "category.food" })
        food.monthlyLimit = 3_000_000
        let jars = try context.fetch(FetchDescriptor<Jar>())
        for (amount, date) in [(2_000_000, at(11, 3)), (500_000, at(11, 6)), (900_000, at(10, 28))] { // the October one doesn't count
            let t = Txn(amount: amount, kind: .expense, currencyCode: "VND", date: date, category: food)
            context.insert(t)
            t.allocate(jars: jars, in: context)
        }
        let reimbursed = Txn(amount: 400_000, kind: .expense, currencyCode: "VND", date: at(11, 6), category: food) // paid back: not counted
        reimbursed.excludedFromReport = true
        context.insert(reimbursed)
        let facts = BudgetFacts(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: try context.fetch(FetchDescriptor<Wallet>()),
                                jars: jars, recurrings: [], now: at(11, 7), calendar: cal)
        let essentials = try #require(facts.jars.first { $0.key == "jar.essentials" })
        let line = try #require(essentials.categories.first { $0.key == "category.food" })
        #expect(line.spent == 2_500_000 && line.left == 500_000 && line.level == .warning)
        #expect(facts.limited.map(\.key) == ["category.food"])
        #expect(essentials.limitsOverBudget) // nothing was split into the jar this month
        #expect(!essentials.categories.contains { $0.key == "category.salary" }) // expense categories only
    }

    @Test func remindersAt80And100() {
        let limits = [ReminderPlanner.JarState(id: "category.food", name: "Food", level: .warning),
                      ReminderPlanner.JarState(id: "category.transport", name: "Transport", level: .over)]
        let medium = ReminderPlanner.plan(limits: limits, settings: .init(level: .medium, horizonDays: 1), now: at(11, 5), calendar: cal)
        #expect(medium.first { $0.kind == .limitWarning }?.keys == ["limit.warn.category.food.2026-11"])
        #expect(medium.first { $0.kind == .limitOver }?.keys == ["limit.over.category.transport.2026-11"])
        // Low level: only past 100%.
        let low = ReminderPlanner.plan(limits: limits, settings: .init(level: .low, horizonDays: 1), now: at(11, 5), calendar: cal)
        #expect(low.map(\.kind) == [.limitOver])
        // Once a month: sent keys (an over alert covers the 80% one), and a jar with the same id is a different alert.
        let again = ReminderPlanner.plan(jars: [.init(id: "category.food", name: "Food", level: .warning)], limits: limits,
                                         settings: .init(level: .medium, horizonDays: 1), now: at(11, 5),
                                         sent: ["limit.over.category.food.2026-11", "limit.over.category.transport.2026-11"], calendar: cal)
        #expect(!again.contains { $0.kind == .limitWarning || $0.kind == .limitOver })
        #expect(again.contains { $0.kind == .jarWarning })
        // The daily cap counts them like any other alert.
        let capped = ReminderPlanner.plan(limits: limits, settings: .init(level: .medium, horizonDays: 1), now: at(11, 5),
                                          deliveredToday: 2, calendar: cal)
        #expect(capped.map(\.kind) == [.limitOver])
    }

    @Test func parserReadsLimitCommands() {
        #expect(QuickParser.limit(in: "đặt hạn mức ăn uống 3tr", context: vnd)! == ("category.food", 3_000_000))
        #expect(QuickParser.limit(in: "dat han muc an uong 3tr", context: vnd)! == ("category.food", 3_000_000))
        #expect(QuickParser.limit(in: "set food limit 3m", context: vnd)! == ("category.food", 3_000_000))
        #expect(QuickParser.limit(in: "ตั้งวงเงินค่าอาหาร 3000", context: vnd)?.categoryKey == "category.food")
        #expect(QuickParser.limit(in: "ຕັ້ງວົງເງິນຄ່າອາຫານ 3000000", context: vnd)?.categoryKey == "category.food")
        #expect(QuickParser.limit(in: "ăn uống tháng này còn bao nhiêu?", context: vnd) == nil) // a question
        #expect(QuickParser.limit(in: "hạn mức ăn uống còn bao nhiêu?", context: vnd) == nil)
        #expect(QuickParser.limit(in: "phở 45k", context: vnd) == nil) // a transaction
        #expect(QuickParser.limit(in: "đặt hạn mức ăn uống", context: vnd) == nil) // no amount
    }

    @Test func chatSetsAndAnswers() async throws {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        Seed.ifNeeded(context)
        let reply = try #require(ChatBook.setLimit("đặt hạn mức ăn uống 3tr", in: context))
        let food = try #require(try context.fetch(FetchDescriptor<Moonee.Category>()).first { $0.key == "category.food" })
        #expect(food.monthlyLimit != nil && reply.contains(food.name))
        #expect(ChatBook.setLimit("phở 45k", in: context) == nil)
        try context.save()

        // "ăn uống tháng này còn bao nhiêu?": the monthBudget fact for the category, rendered without a model.
        let tools = MooneeTools(ledger: StoreLedger(context))
        let json = try await tools.monthBudget.run(Data(#"{"categoryKey":"category.food"}"#.utf8))
        let text = try #require(ChatBook.factsText([.init(tool: "monthBudget", json: json)]))
        #expect(text.contains(food.name) && text.contains(Money(food.monthlyLimit!, Money.defaultCurrency).formatted()))
        // A category without a limit: monthBudget steps aside for the spending summary.
        let plain = try await tools.monthBudget.run(Data(#"{"categoryKey":"category.transport"}"#.utf8))
        #expect(ChatBook.factsText([.init(tool: "monthBudget", json: plain)]) == nil)
        #expect(Skill.route("hạn mức ăn uống còn bao nhiêu?", context: ParserContext(context)).id == "jar-budgeting")
    }
}
