import Foundation
import SwiftData

/// The stored books as plain values for the AI tools (`LedgerReading`) and any screen that wants them.
/// A snapshot taken on the main actor: build a fresh one per question.
// ponytail: reads every txn of the currency; fetch by date range once ledgers get big.
struct StoreLedger: LedgerReading {
    let currency: String
    let jarList: [LedgerJar]
    let txns: [LedgerTxn]
    let budgetFacts: BudgetFacts
    let debtList: [LedgerDebt]

    @MainActor init(_ context: ModelContext, currency: String = Money.defaultCurrency, now: Date = .now, calendar: Calendar = .current) {
        let txns = (try? context.fetch(FetchDescriptor<Txn>())) ?? []
        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let wallets = (try? context.fetch(FetchDescriptor<Wallet>())) ?? []
        let ledger = Ledger(txns: txns, wallets: wallets, jars: jars)
        budgetFacts = BudgetFacts(txns: txns, wallets: wallets, jars: jars,
                                  recurrings: (try? context.fetch(FetchDescriptor<Recurring>())) ?? [], now: now, calendar: calendar)
        self.currency = currency
        debtList = ((try? context.fetch(FetchDescriptor<Debt>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []).compactMap { d in
            guard let left = ledger.debtRemaining[d.persistentModelID], left > 0 else { return nil }
            return LedgerDebt(person: d.person, theyOweMe: d.direction == .lent, remaining: left, dueDate: d.dueDate)
        }
        jarList = jars.map { LedgerJar(key: $0.parserKey, name: $0.name, percent: $0.percent, balance: ledger.jarBalance($0.persistentModelID)) }
        // Not-counted txns (P1-2) stay out of the assistant's spending sums, like every report.
        self.txns = txns.filter { $0.currencyCode == currency && !$0.excludedFromReport }.map { t in
            LedgerTxn(date: t.date, amount: t.amount, kind: EntryKind(rawValue: t.kindRaw) ?? .expense,
                      categoryKey: t.category?.parserKey, categoryName: t.category?.name,
                      jarKey: t.jar?.parserKey, toJarKey: t.toJar?.parserKey,
                      splits: Dictionary((t.splits ?? []).compactMap { s in s.jar.map { ($0.parserKey, s.amount) } }, uniquingKeysWith: +),
                      note: t.note, person: t.debt?.person)
        }
    }

    func jars() async throws -> [LedgerJar] { jarList }
    func budget() async throws -> BudgetFacts? { budgetFacts }
    func debts() async throws -> [LedgerDebt] { debtList }
    func transactions(in i: DateInterval) async throws -> [LedgerTxn] { txns.filter { $0.date >= i.start && $0.date < i.end } }
}

/// The Budget tab's numbers for one month, all from `Ledger`. The Budget tab shows them and the assistant's
/// `monthBudget` tool reads the very same struct, so "how much can I still spend?" matches the screen (spec §9.3).
struct BudgetFacts: Sendable, Equatable {
    struct JarLine: Sendable, Equatable {
        var key: String
        var name: String
        var percent: Int
        /// Carried over from before the month, added during it (income splits, moves), spent, balance at the end.
        var start, added, spent, balance: Int
        /// Assets bought / savings deposits out of the jar this month ("Set aside"): not spending, not in `budget`.
        var setAside = 0
        /// The jar's expense categories this month, with their limits (spec P1-1).
        var categories: [CategoryLine] = []
        /// "Available this month": start + added.
        var budget: Int { start + added }
        /// Σ category limits in the jar.
        var limits: Int { categories.reduce(0) { $0 + ($1.limit ?? 0) } }
        /// "Limits are more than this jar has": the limits promise money the jar didn't get this month.
        var limitsOverBudget: Bool { limits > max(budget, 0) }
    }

    /// One category's month: spent against its monthly limit (nil = no limit). A limit holds no money: the jar does.
    struct CategoryLine: Sendable, Equatable {
        var key: String
        var name: String
        var limit: Int?
        var spent: Int
        /// What is left under the limit (negative = over), nil without a limit.
        var left: Int? { limit.map { $0 - spent } }
        /// 80% → warning, past 100% → over, the same colours as jars. nil without a limit.
        var level: BudgetLevel? { limit.map { BudgetLevel(spent: spent, budget: $0) } }

        /// Spent this month per category (expenses only, never ones kept out of reports), minor units.
        @MainActor static func spent(_ txns: [Txn], in month: DateInterval) -> [PersistentIdentifier: Int] {
            txns.reduce(into: [:]) { sums, t in
                if t.kind == .expense, !t.excludedFromReport, month.contains(t.date), let c = t.category { sums[c.persistentModelID, default: 0] += t.amount }
            }
        }

        /// A jar's expense categories in their order.
        @MainActor static func categories(of jar: Jar) -> [Category] {
            (jar.categories ?? []).filter { $0.kind == .expense }.sorted { $0.order < $1.order }
        }

        @MainActor static func lines(_ jar: Jar, spent: [PersistentIdentifier: Int]) -> [CategoryLine] {
            categories(of: jar).map { CategoryLine($0, spent: spent) }
        }
    }

    struct Due: Sendable, Equatable {
        var name: String
        var amount: Int
        var date: Date
        var isEstimate = false
    }

    var month: DateInterval
    var jars: [JarLine]
    /// Wallet money no jar holds yet (now, whatever the month). Positive = to split.
    var unallocated: Int
    /// Income received in the month (the Overview's month income is the same number).
    var income: Int
    /// Salaries and other income recurrings not received yet, next payday first.
    var expectedIncome: [Due]
    /// Unpaid bills due before the month ends, overdue ones included.
    var bills: [Due]
    /// Moonee's advice now (spec §4.6), the same the Budget card and chat show.
    var advisor: BudgetAdvisor
    var advice: [BudgetAdvisor.Advice] { month.contains(advisor.input.now) ? advisor.advice : [] }

    /// "Available this month": what the jars have for the month (start of month + added).
    var budget: Int { jars.reduce(0) { $0 + $1.budget } }
    var spent: Int { jars.reduce(0) { $0 + $1.spent } }
    var setAside: Int { jars.reduce(0) { $0 + $1.setAside } }
    /// "Left to spend this month" = Σ jar balances at the month's end = budget − spent − set aside.
    var left: Int { jars.reduce(0) { $0 + $1.balance } }
    /// "About X a day": `left` over the days left in the month (today included), on a clean step. 0 outside this month.
    var perDay: Int { month.contains(advisor.input.now) ? advisor.perDay(left) : 0 }
    var billsTotal: Int { bills.reduce(0) { $0 + $1.amount } }
    /// Categories with a monthly limit, every jar.
    var limited: [CategoryLine] { jars.flatMap(\.categories).filter { $0.limit != nil } }

    @MainActor init(txns: [Txn], wallets: [Wallet], jars: [Jar], recurrings: [Recurring], month: DateInterval? = nil,
                    now: Date = .now, calendar: Calendar = .current, level: AdvisorLevel = .current,
                    muted: Set<BudgetAdvisor.Kind> = AdvisorMemory.muted) {
        let ledger = Ledger(txns: txns, wallets: wallets, jars: jars)
        advisor = BudgetAdvisor(.init(txns: txns, wallets: wallets, jars: jars, recurrings: recurrings, ledger: ledger, now: now,
                                      calendar: calendar, level: level, muted: muted))
        let month = month ?? calendar.dateInterval(of: .month, for: now)!
        self.month = month
        let byCategory = CategoryLine.spent(txns, in: month)
        self.jars = jars.sorted { $0.order < $1.order }.map { j in
            let m = ledger.jarMonth(j.persistentModelID, in: month)
            return JarLine(key: j.parserKey, name: j.name, percent: j.percent, start: m.start, added: m.added, spent: m.spent,
                           balance: m.endBalance, setAside: m.setAside, categories: CategoryLine.lines(j, spent: byCategory))
        }
        unallocated = ledger.unallocated
        income = ledger.income(in: month)
        expectedIncome = recurrings.filter(\.isIncome).map { r in
            let received = BudgetActions.isReceived(r, txns: txns, calendar: calendar)
            let date = received ? BudgetActions.nextDue(after: r.nextDue, r.frequency, day: r.dueDay, calendar: calendar) : r.nextDue
            return Due(name: r.name, amount: r.amount, date: date, isEstimate: r.isEstimate)
        }.sorted { $0.date < $1.date }
        bills = recurrings.filter { !$0.isIncome && $0.nextDue < month.end }.sorted { $0.nextDue < $1.nextDue }
            .map { Due(name: $0.name, amount: $0.amount, date: $0.nextDue, isEstimate: $0.isEstimate) }
    }
}

extension BudgetFacts.CategoryLine {
    @MainActor init(_ c: Category, spent: [PersistentIdentifier: Int]) {
        self.init(key: c.parserKey, name: c.name, limit: c.monthlyLimit, spent: spent[c.persistentModelID] ?? 0)
    }
}

extension BudgetFacts {
    /// This month's facts and advice from the store.
    @MainActor init(_ context: ModelContext, now: Date = .now, calendar: Calendar = .current, level: AdvisorLevel = .current) {
        self.init(txns: (try? context.fetch(FetchDescriptor<Txn>())) ?? [], wallets: (try? context.fetch(FetchDescriptor<Wallet>())) ?? [],
                  jars: (try? context.fetch(FetchDescriptor<Jar>())) ?? [], recurrings: (try? context.fetch(FetchDescriptor<Recurring>())) ?? [],
                  now: now, calendar: calendar, level: level)
    }
}

extension ParserContext {
    /// What the parser should know from the store: wallets, jar and category names, learned merchant rules.
    @MainActor init(_ context: ModelContext, now: Date = .now) {
        self.init()
        currency = Money.defaultCurrency
        self.now = now
        wallets = ((try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.order)]))) ?? []).map(\.name)
        let byName = { (pairs: [(String, String)]) in Dictionary(pairs, uniquingKeysWith: { a, _ in a }) }
        jars = byName(((try? context.fetch(FetchDescriptor<Jar>())) ?? []).map { ($0.name, $0.parserKey) })
        categories = byName(((try? context.fetch(FetchDescriptor<Category>())) ?? []).map { ($0.name, $0.parserKey) })
        merchantRules = byName(((try? context.fetch(FetchDescriptor<MerchantRule>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? [])
            .compactMap { r in r.category.map { (r.pattern, $0.parserKey) } })
    }
}

// The parser and tools speak keys; user-made jars/categories have none, so they get one from their name.
// ponytail: renaming a custom category orphans its merchant-rule key text; use a stored UUID if renames matter.
extension Category {
    var parserKey: String { key ?? "category.custom.\(customName ?? "")" }
}

extension Jar {
    var parserKey: String { key ?? "jar.custom.\(customName ?? "")" }
}
