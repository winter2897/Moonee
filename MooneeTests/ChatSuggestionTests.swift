import Foundation
import SwiftData
import Testing
@testable import Moonee

/// The chat's three question tiles (`ChatSuggestion.pick`) and their offline answers (no model: the tools' numbers).
@MainActor struct ChatSuggestionTests {
    let cal = Calendar.current
    let cur = Money.defaultCurrency
    let context: ModelContext

    init() throws {
        context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        Seed.ifNeeded(context)
    }

    func at(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }
    var jars: [Jar] { (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? [] }
    var cash: Wallet { try! context.fetch(FetchDescriptor<Wallet>()).first! }
    func category(_ key: String) -> Moonee.Category { try! context.fetch(FetchDescriptor<Moonee.Category>()).first { $0.key == key }! }
    func money(_ minor: Int) -> String { Money(minor, cur).formatted() }

    @discardableResult func add(_ amount: Int, _ kind: TxKind, _ date: Date, category key: String? = nil) -> Txn {
        let t = Txn(amount: amount, kind: kind, date: date, category: key.map(category), wallet: cash)
        context.insert(t)
        t.allocate(jars: jars, in: context)
        return t
    }

    func pick(_ now: Date) -> [ChatSuggestion] {
        let books = StoreLedger(context, now: now, calendar: cal)
        return ChatSuggestion.pick(facts: books.budgetFacts, debts: books.debtList, currency: cur, now: now, calendar: cal)
    }

    /// The Vietnamese books of a busy month: salary split into jars, Essentials 91% used, food past 80% of its limit,
    /// a bill due in 3 days, Nam owing money since last week, and last month's spending to compare with.
    func busyMonth(now: Date) {
        add(10_000_000, .income, at(10, 5), category: "category.salary")
        add(5_500_000, .expense, at(10, 20), category: "category.food") // Essentials ends October empty
        add(10_000_000, .income, at(11, 1), category: "category.salary")
        add(2_500_000, .expense, at(11, 10), category: "category.food")
        add(2_500_000, .expense, cal.date(byAdding: .day, value: -1, to: now)!, category: "category.housing")
        category("category.food").monthlyLimit = 3_000_000
        let bill = Recurring(name: "Internet", amount: 300_000, nextDue: cal.date(byAdding: .day, value: 3, to: now)!)
        context.insert(bill)
        let debt = Debt(person: "Nam", direction: .lent, dueDate: cal.date(byAdding: .day, value: -6, to: now)!)
        context.insert(debt)
        let lend = add(500_000, .lend, at(11, 2))
        lend.debt = debt
        try? context.save()
    }

    // MARK: - Picker

    @Test func emptyBooksMidMonth() {
        let kinds = pick(at(11, 15)).map(\.kind)
        #expect(kinds == [.today, .topThisWeek, .compareMonths])
    }

    @Test func monthPhasePicksTheThirdTile() {
        #expect(pick(at(11, 3)).map(\.kind) == [.today, .topThisWeek, .lastMonthReport]) // first 5 days: last month's report
        #expect(pick(at(11, 3)).last?.action == .openReport)
        #expect(pick(at(11, 28)).map(\.kind) == [.today, .topThisWeek, .compareMonths]) // last days: compare
    }

    @Test func unallocatedMoneyComesFirst() {
        cash.initialBalance = 2_000_000
        context.insert(Recurring(name: "Điện", amount: 400_000, nextDue: at(11, 20)))
        let s = pick(at(11, 15))
        #expect(s.map(\.kind) == [.split, .dueSoon, .today])
        #expect(s[0].action == .openSplit && s[0].title.contains(AmountFormat.string(2_000_000, cur, short: true)))
        // A bill 10 days away is not "soon".
        #expect(pick(at(11, 9)).map(\.kind) == [.split, .today, .topThisWeek])
    }

    @Test func busyMonthShowsAtMostTwoActions() {
        let now = at(11, 17)
        busyMonth(now: now)
        let s = pick(now)
        #expect(s.map(\.kind) == [.dueSoon, .lowJar, .today])
        let essentials = jars.first { $0.key == "jar.essentials" }!
        #expect(s[1].title.contains(essentials.name))
        // Bill paid and nothing else due: the overdue receivable shows up next.
        context.delete(try! context.fetch(FetchDescriptor<Recurring>()).first!)
        #expect(pick(now).map(\.kind) == [.lowJar, .owedToMe, .today])
    }

    @Test func categoryLimitAloneShowsWithTheDailyQuestion() {
        add(10_000_000, .income, at(11, 1), category: "category.salary")
        add(2_500_000, .expense, at(11, 10), category: "category.food")
        category("category.food").monthlyLimit = 3_000_000
        let s = pick(at(11, 15))
        #expect(s.map(\.kind) == [.categoryLimit, .today, .topThisWeek])
        #expect(s[0].title.contains(category("category.food").name))
    }

    // MARK: - Offline answers

    /// What Moonee says to `question` with no model: the skill's tool facts as text.
    func answer(_ question: String, now: Date) async throws -> String {
        let tools = MooneeTools(ledger: StoreLedger(context, now: now, calendar: cal), now: { now }, calendar: cal)
        let assistant = Assistant(router: AIRouter(mode: .local, local: nil, cloud: nil), tools: tools, language: "vi", skillsOff: [])
        let reply = await assistant.reply(question, context: ParserContext(context, now: now))
        guard case .facts(let facts, _) = reply.output else { Issue.record("not facts: \(reply.output)"); return "" }
        return try #require(ChatBook.factsText(facts), "\(question): \(facts)")
    }

    @Test func everyTileIsAnsweredOffline() async throws {
        let now = at(11, 17)
        busyMonth(now: now)
        let facts = StoreLedger(context, now: now, calendar: cal).budgetFacts
        let essentials = jars.first { $0.key == "jar.essentials" }!
        let food = category("category.food")
        // The picker's own titles (the test bundle's language) and the owner's Vietnamese wording.
        let titles = Dictionary(uniqueKeysWithValues: pick(now).map { ($0.kind, $0.title) })
        let cases: [(question: String, expect: [String])] = [
            (titles[.dueSoon]!, ["Internet", money(300_000)]),
            ("Sắp tới phải trả gì?", ["Internet", money(300_000)]),
            (titles[.lowJar]!, [essentials.name, money(facts.advisor.perDay(facts.jars[0].balance))]),
            ("Lọ Thiết yếu sắp hết, làm sao?", [essentials.name]),
            ("Who owes me money?", ["Nam", money(500_000)]),
            ("Ai đang nợ mình?", ["Nam", money(500_000)]),
            ("How much is left for \(food.name)?", [money(3_000_000), money(500_000)]),
            ("Ăn uống còn bao nhiêu?", [money(3_000_000), money(500_000)]),
            (titles[.today]!, [money(facts.perDay)]),
            ("Hôm nay còn tiêu được bao nhiêu?", [money(facts.perDay)]),
            ("Where did I spend the most this week?", [category("category.housing").name, money(2_500_000)]),
            ("Tuần này mình tiêu nhiều nhất vào đâu?", [category("category.housing").name, money(2_500_000)]),
            ("How does this month compare with last month?", [money(5_000_000), "-9%"]),
            ("Tháng này so với tháng trước thế nào?", [money(5_000_000), "-9%"]),
            ("Xem báo cáo tháng trước", [money(10_000_000), money(5_500_000)]),
        ]
        #expect(facts.perDay > 0)
        for c in cases {
            let text = try await answer(c.question, now: now)
            for e in c.expect { #expect(text.contains(e), "\(c.question) → \(text) lacks \(e)") }
        }
        // Nothing due: Moonee says so instead of the month's budget.
        context.delete(try! context.fetch(FetchDescriptor<Recurring>()).first!)
        #expect(try await answer("Sắp tới phải trả gì?", now: now) == String(localized: "Nothing to pay in the next 7 days.", table: "Chat"))
    }

    @Test func questionsNameTheirPeriodsInOrder() {
        #expect(QuickParser.periods(in: "Tháng này so với tháng trước thế nào?") == ["thisMonth", "lastMonth"])
        #expect(QuickParser.periods(in: "so với tháng trước, tháng này thế nào?") == ["lastMonth", "thisMonth"])
        #expect(QuickParser.hints(in: "How does this month compare with last month?").period == "thisMonth")
        #expect(QuickParser.periods(in: "cafe 30k").isEmpty)
    }
}
