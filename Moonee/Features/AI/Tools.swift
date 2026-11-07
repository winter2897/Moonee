import Foundation

/// The Swift functions skills may call (spec §9.3: "every number comes from the app").
/// Results are JSON with amounts already formatted, so models quote numbers instead of computing them.
struct MooneeTools: Sendable {
    let ledger: any LedgerReading
    var now: @Sendable () -> Date = { .now }
    var calendar = Calendar.current
    /// Formats money for the reply language.
    var locale = Locale.current
    /// Outside info (market-lookup skill only): web search backend and crypto prices.
    var search = WebSearch.current()
    var prices = MarketPrices()

    var all: [AITool] { [monthBudget, spendingSummary, listTransactions, jarBalances, splitIncome, savingsPlan, monthClose, webSearch, marketPrice, debtBook] }

    /// Every tool name, for skill files and the skill editor (a test keeps it equal to `all`).
    static let allNames = ["monthBudget", "spendingSummary", "listTransactions", "jarBalances", "splitIncome", "savingsPlan", "monthClose",
                           "webSearch", "marketPrice", "debtBook"]

    /// In the order given (a skill lists its most useful tool first).
    func named(_ names: [String]) -> [AITool] {
        let tools = all
        return names.compactMap { n in tools.first { $0.name == n } }
    }

    // MARK: Tools

    var monthBudget: AITool {
        AITool(name: "monthBudget",
               description: "This month's budget exactly as the Budget tab shows it: total budget the jars hold, spent, left to spend, left after the bills still due, money in wallets not split into jars yet, income received, the expected salary and payday, unpaid bills due this month, each jar's budget, spent and left, and Moonee's advice now (the plan with its numbers and why, the same as the Budget card). Explain the advice; never change its numbers.",
               parameters: .object([])) { (_: ToolArgs) -> BudgetReply in
            guard let b = try await ledger.budget() else { throw LLMError("budget unavailable") }
            let due = { (d: BudgetFacts.Due) in BudgetReply.Due(name: d.name, amount: money(d.amount), date: day(d.date), estimate: d.isEstimate ? true : nil) }
            return BudgetReply(
                month: "\(day(b.month.start)) – \(day(b.month.end.addingTimeInterval(-1)))", today: day(now()),
                totalBudget: money(b.budget), spent: money(b.spent), left: money(b.left),
                billsStillDue: money(b.billsTotal), leftAfterBills: money(b.left - b.billsTotal),
                unallocated: money(b.unallocated), incomeReceived: money(b.income),
                expectedIncome: b.expectedIncome.map(due), billsDueThisMonth: b.bills.map(due),
                jars: b.jars.map { .init(name: $0.name, budget: money($0.budget), spent: money($0.spent), left: money($0.balance)) },
                advice: b.advice.map { .init(kind: $0.kind.rawValue, title: $0.title, text: $0.text, why: $0.why) })
        }
    }

    var spendingSummary: AITool {
        AITool(name: "spendingSummary",
               description: "Spending and income for a period, compared with the period before, with the top categories. Optional filter by category or jar.",
               parameters: .object([Self.period, Self.category, Self.jar])) { (a: ToolArgs) -> Summary in
            let p = a.period ?? .thisMonth
            let cur = p.interval(now: now(), calendar: calendar), prev = p.previous(now: now(), calendar: calendar)
            let txns = try await ledger.transactions(in: DateInterval(start: min(prev.start, cur.start), end: cur.end))
            func spending(_ i: DateInterval) -> [LedgerTxn] {
                txns.filter {
                    $0.kind == .expense && i.has($0.date) && (a.categoryKey == nil || $0.categoryKey == a.categoryKey)
                        && (a.jarKey == nil || $0.jarKey == a.jarKey)
                }
            }
            let now = spending(cur), before = spending(prev)
            let spent = now.sum, previous = before.sum
            return Summary(
                period: p.rawValue, from: day(cur.start), to: day(cur.end.addingTimeInterval(-1)),
                spent: money(spent), previousSpent: money(previous),
                change: previous > 0 ? signedPercent(spent - previous, of: previous) : nil,
                income: money(txns.filter { $0.kind == .income && cur.has($0.date) }.sum),
                transactionCount: now.count,
                topCategories: top(now, total: spent))
        }
    }

    var listTransactions: AITool {
        AITool(name: "listTransactions",
               description: "The latest transactions of a period, newest first. Optional filter by category, jar or kind.",
               parameters: .object([Self.period, Self.category, Self.jar,
                                    .init("kind", .string(oneOf: EntryKind.allCases.map(\.rawValue))),
                                    .init("limit", .integer("How many, default 10, at most 50"))])) { (a: ToolArgs) -> [Row] in
            let i = (a.period ?? .thisMonth).interval(now: now(), calendar: calendar)
            return try await ledger.transactions(in: i)
                .filter {
                    i.has($0.date) && (a.kind == nil || $0.kind == a.kind) && (a.categoryKey == nil || $0.categoryKey == a.categoryKey)
                        && (a.jarKey == nil || $0.jarKey == a.jarKey)
                }
                .sorted { $0.date > $1.date }
                .prefix(min(max(a.limit ?? 10, 1), 50))
                .map { Row(date: day($0.date), kind: $0.kind.rawValue, amount: money($0.amount),
                           category: $0.categoryName ?? $0.categoryKey, note: $0.note, person: $0.person) }
        }
    }

    var jarBalances: AITool {
        AITool(name: "jarBalances",
               description: "Every jar's balance now, what came in and went out this month, and how much of this month's money is used (warning from 80%).",
               parameters: .object([])) { (_: ToolArgs) -> [JarRow] in
            let month = LedgerPeriod.thisMonth.interval(now: now(), calendar: calendar)
            let since = try await ledger.transactions(in: DateInterval(start: month.start, end: .distantFuture))
            let all = JarFlows(since), inMonth = JarFlows(since.filter { month.has($0.date) })
            return try await ledger.jars().map { j in
                let opening = j.balance - all.net(j.key)
                let funded = inMonth.inflow[j.key, default: 0], spent = inMonth.outflow[j.key, default: 0]
                let base = opening + funded
                let used = base > 0 ? Double(spent) / Double(base) : (spent > 0 ? 9.99 : 0)
                return JarRow(key: j.key, name: j.name, percent: "\(j.percent)%", balance: money(j.balance),
                              fundedThisMonth: money(funded), spentThisMonth: money(spent),
                              usedThisMonth: base > 0 ? "\(Int((used * 100).rounded()))%" : nil,
                              status: j.balance < 0 ? "negative" : used > 1 ? "over" : used >= 0.8 ? "warning" : "ok")
            }
        }
    }

    var splitIncome: AITool {
        AITool(name: "splitIncome",
               description: "How an income would be split into the jars by their percentages.",
               parameters: .object([.init("amountText", .string("The amount in the user's own words, e.g. \"15tr\" or \"$3,000\""), required: true)])) {
            (a: ToolArgs) -> Split in
            let amount = try parse(a.amountText)
            let jars = try await ledger.jars()
            var shares = jars.map { amount * $0.percent / 100 }
            if let big = jars.indices.max(by: { jars[$0].percent < jars[$1].percent }), jars.map(\.percent).reduce(0, +) == 100 {
                shares[big] += amount - shares.reduce(0, +) // rounding leftovers go to the biggest jar
            }
            return Split(amount: money(amount), jars: jars.indices.map {
                .init(key: jars[$0].key, name: jars[$0].name, percent: "\(jars[$0].percent)%", amount: money(shares[$0]))
            })
        }
    }

    var savingsPlan: AITool {
        AITool(name: "savingsPlan",
               description: "How much to put aside per week and per month to reach a target by a date.",
               parameters: .object([
                   .init("targetText", .string("The goal amount in the user's words, e.g. \"30tr\""), required: true),
                   .init("deadline", .string("The date to reach it, yyyy-MM-dd"), required: true),
                   .init("savedText", .string("Already saved, in the user's words")),
               ])) { (a: ToolArgs) -> Plan in
            let target = try parse(a.targetText), saved = a.savedText == nil ? 0 : try parse(a.savedText)
            guard let text = a.deadline,
                  let deadline = try? Date(text, strategy: Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
            else { throw LLMError("deadline must be yyyy-MM-dd") }
            let today = calendar.startOfDay(for: now())
            guard let days = calendar.dateComponents([.day], from: today, to: deadline).day, days > 0 else {
                throw LLMError("deadline must be in the future")
            }
            let m = calendar.dateComponents([.month, .day], from: today, to: deadline)
            let months = max(1, (m.month ?? 0) + ((m.day ?? 0) > 0 ? 1 : 0)), weeks = (days + 6) / 7
            let remaining = max(0, target - saved)
            return Plan(target: money(target), saved: money(saved), remaining: money(remaining), deadline: text, daysLeft: days,
                        perWeek: money((remaining + weeks - 1) / weeks), perMonth: money((remaining + months - 1) / months))
        }
    }

    var monthClose: AITool {
        AITool(name: "monthClose",
               description: "Month-end close: income, spending and savings rate, each jar's opening and closing (carried over) balance, negative jars with suggested moves to cover them, and uncategorized spending.",
               parameters: .object([.init("month", .string("thisMonth (default) or lastMonth", oneOf: ["thisMonth", "lastMonth"]))])) {
            (a: ToolArgs) -> Close in
            let m = (a.month ?? .thisMonth).interval(now: now(), calendar: calendar)
            let txns = try await ledger.transactions(in: DateInterval(start: m.start, end: .distantFuture))
            let inMonth = txns.filter { m.has($0.date) }
            let after = JarFlows(txns.filter { $0.date >= m.end }), flows = JarFlows(inMonth)

            let start: [(jar: LedgerJar, opening: Int, closing: Int)] = try await ledger.jars().map { j in
                let closing = j.balance - after.net(j.key)
                return (j, closing - flows.net(j.key), closing)
            }
            // Cover each negative jar in Moonee's order (spec §4.6, `BudgetAdvisor.cover`): Play → Growth → Giving →
            // own jars → Savings / Investing last; Essentials is never the source.
            let rank: (LedgerJar) -> Int? = { j in
                switch BudgetAdvisor.Role(key: j.key) {
                case .play: 0
                case .growth: 1
                case .giving: 2
                case .other: 3
                case .savings: 4
                case .investing: 5
                case .essentials: nil
                }
            }
            var rows = start, moves: [Close.Move] = []
            for i in rows.indices {
                while rows[i].closing < 0, let d = rows.indices.filter({ rows[$0].closing > 0 && rank(rows[$0].jar) != nil })
                    .min(by: { rank(rows[$0].jar)! < rank(rows[$1].jar)! }) {
                    let amount = min(-rows[i].closing, rows[d].closing)
                    rows[d].closing -= amount
                    rows[i].closing += amount
                    moves.append(.init(from: rows[d].jar.name, to: rows[i].jar.name, amount: money(amount)))
                }
            }
            let spending = inMonth.filter { $0.kind == .expense }
            let income = inMonth.filter { $0.kind == .income }.sum, spent = spending.sum
            return Close(
                month: "\(day(m.start)) – \(day(m.end.addingTimeInterval(-1)))", income: money(income), spent: money(spent),
                saved: money(income - spent), savingsRate: income > 0 ? signedPercent(income - spent, of: income) : nil,
                jars: start.map {
                    .init(name: $0.jar.name, opening: money($0.opening), funded: money(flows.inflow[$0.jar.key, default: 0]),
                          spent: money(flows.outflow[$0.jar.key, default: 0]), closing: money($0.closing))
                },
                negativeJars: start.filter { $0.closing < 0 }.map(\.jar.name),
                suggestedMoves: moves,
                uncategorizedCount: spending.filter { $0.categoryKey == nil && $0.categoryName == nil }.count,
                topCategories: top(spending, total: spent))
        }
    }

    var webSearch: AITool {
        AITool(name: "webSearch",
               description: "Search the web for current outside information (gold prices, exchange rates, interest rates, news). Returns titles, URLs, snippets, dates and when the search ran. Cite them.",
               parameters: .object([.init("query", .string("What to search for, in the user's language"), required: true)])) {
            (a: ToolArgs) -> SearchResult in
            guard let q = a.query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { throw LLMError("query is empty") }
            return await search.run(q)
        }
    }

    var marketPrice: AITool {
        AITool(name: "marketPrice",
               description: "Current reference price from the internet with update time, no web search needed: crypto (BTC, ETH, SOL…), Vietnamese gold (SJC, PNJ or GOLD, per tael) and exchange rates in VND (USD, EUR, JPY…). Not for stocks or interest rates: use webSearch.",
               parameters: .object([.init("symbol", .string("BTC, ethereum, SJC, PNJ, GOLD, USD, EUR…"), required: true)])) {
            (a: ToolArgs) -> MarketPrices.Quote in
            guard let symbol = a.symbol else { throw LLMError("symbol is missing") }
            return try await prices.quote(symbol, currency: ledger.currency, locale: locale)
        }
    }

    var debtBook: AITool {
        AITool(name: "debtBook",
               description: "The debt book: who owes the user money (theyOweMe) and whom the user owes (iOwe), each open debt with what is still owed and the due date (null = no due date), plus both totals. Settled debts are not listed.",
               parameters: .object([])) { (_: ToolArgs) -> DebtReply in
            let debts = try await ledger.debts()
            let row = { (d: LedgerDebt) in DebtReply.Row(person: d.person, left: money(d.remaining), due: d.dueDate.map(day)) }
            let mine = debts.filter(\.theyOweMe), theirs = debts.filter { !$0.theyOweMe }
            return DebtReply(today: day(now()), owedToMe: money(mine.reduce(0) { $0 + $1.remaining }), theyOweMe: mine.map(row),
                             owedByMe: money(theirs.reduce(0) { $0 + $1.remaining }), iOwe: theirs.map(row))
        }
    }

    // MARK: Helpers

    private func top(_ spending: [LedgerTxn], total: Int) -> [Summary.Category] {
        Dictionary(grouping: spending) { $0.categoryName ?? $0.categoryKey ?? "uncategorized" }
            .map { (name: $0.key, sum: $0.value.sum) }
            .sorted { $0.sum > $1.sum }
            .prefix(3)
            .map { row -> Summary.Category in
                let percent = total > 0 ? Int((Double(row.sum) * 100 / Double(total)).rounded()) : 0
                return .init(name: row.name, spent: money(row.sum), share: "\(percent)%")
            }
    }

    private func money(_ minor: Int) -> String { Money(minor, ledger.currency).formatted(locale: locale) }

    private func signedPercent(_ part: Int, of whole: Int) -> String {
        let p = Int((Double(part) * 100 / Double(whole)).rounded())
        return (p > 0 ? "+" : "") + "\(p)%"
    }

    private func day(_ d: Date) -> String { d.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()) }

    private func parse(_ text: String?) throws -> Int {
        var c = ParserContext()
        (c.currency, c.now, c.calendar) = (ledger.currency, now(), calendar)
        guard let text, let a = QuickParser.amount(in: text, context: c), a.currency == ledger.currency else {
            throw LLMError("no amount in \(text ?? "nil") for \(ledger.currency)")
        }
        return a.amount
    }

    private static let period = ToolSchema.Property("period", .string("Default thisMonth", oneOf: LedgerPeriod.allCases.map(\.rawValue)))
    private static let category = ToolSchema.Property("categoryKey", .string("Only this category key, e.g. category.food"))
    private static let jar = ToolSchema.Property("jarKey", .string("Only this jar key, e.g. jar.play"))
}

/// One argument bag for every tool: the model sends what a tool's schema asks for; pre-fetching sends the same hints to all.
struct ToolArgs: Codable, Sendable {
    var period: LedgerPeriod?
    var month: LedgerPeriod?
    var categoryKey: String?
    var jarKey: String?
    var kind: EntryKind?
    var limit: Int?
    var amountText: String?
    var targetText: String?
    var savedText: String?
    var deadline: String?
    var query: String?
    var symbol: String?
}

// MARK: - Results

struct BudgetReply: Encodable {
    struct Due: Encodable { var name, amount, date: String; var estimate: Bool? }
    struct Jar: Encodable { var name, budget, spent, left: String }
    /// `BudgetAdvisor` output: numbers already in the text.
    struct Advice: Encodable { var kind, title, text: String; var why: String? }
    var month, today, totalBudget, spent, left, billsStillDue, leftAfterBills, unallocated, incomeReceived: String
    var expectedIncome: [Due]
    var billsDueThisMonth: [Due]
    var jars: [Jar]
    var advice: [Advice]
}

struct DebtReply: Codable {
    struct Row: Codable { var person, left: String; var due: String? }
    var today, owedToMe: String
    var theyOweMe: [Row]
    var owedByMe: String
    var iOwe: [Row]
}

struct Summary: Encodable {
    struct Category: Encodable { var name: String; var spent: String; var share: String }
    var period, from, to, spent, previousSpent: String
    var change: String?
    var income: String
    var transactionCount: Int
    var topCategories: [Category]
}

struct Row: Encodable {
    var date, kind, amount: String
    var category: String?
    var note: String
    var person: String?
}

struct JarRow: Encodable {
    var key, name, percent, balance, fundedThisMonth, spentThisMonth: String
    var usedThisMonth: String?
    /// ok, warning (≥80%), over (>100%), negative
    var status: String
}

struct Split: Encodable {
    struct Share: Encodable { var key, name, percent, amount: String }
    var amount: String
    var jars: [Share]
}

struct Plan: Encodable {
    var target, saved, remaining, deadline: String
    var daysLeft: Int
    var perWeek, perMonth: String
}

struct Close: Encodable {
    struct JarLine: Encodable { var name, opening, funded, spent, closing: String }
    struct Move: Encodable { var from, to, amount: String }
    var month, income, spent, saved: String
    var savingsRate: String?
    var jars: [JarLine]
    var negativeJars: [String]
    var suggestedMoves: [Move]
    var uncategorizedCount: Int
    var topCategories: [Summary.Category]
}

private extension DateInterval {
    /// Half-open: the end belongs to the next period.
    func has(_ d: Date) -> Bool { d >= start && d < end }
}

private extension [LedgerTxn] {
    var sum: Int { reduce(0) { $0 + $1.amount } }
}
