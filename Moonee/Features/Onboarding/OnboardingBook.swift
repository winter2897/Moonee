import Foundation
import SwiftData

extension Prefs {
    /// Bool. First-launch onboarding (spec §7) finished or skipped. Launch with `-onboarding.done YES` to skip it.
    static let onboardingDone = "onboarding.done"
    /// Int, minor units of the default currency. Monthly income given in onboarding (a range midpoint or typed).
    static let monthlyIncome = "profile.monthlyIncome"
    /// Bool. Income is a regular salary (false = it varies month to month).
    static let incomeRegular = "profile.incomeRegular"
}

/// Every write onboarding makes, plus the pure rules behind its suggestions. No UI, so it is unit-tested.
@MainActor enum OnboardingBook {
    // MARK: Income

    /// Monthly income chips, sized to what people earn in that currency (major units). Mid = the amount stored for the chip.
    nonisolated static let incomeScales: [String: (bounds: [Decimal], mids: [Decimal])] = [
        "VND": ([10_000_000, 20_000_000, 40_000_000], [7_000_000, 15_000_000, 30_000_000, 50_000_000]),
        "THB": ([15_000, 30_000, 60_000], [10_000, 22_000, 45_000, 80_000]),
        "LAK": ([3_000_000, 6_000_000, 12_000_000], [2_000_000, 4_500_000, 9_000_000, 15_000_000]),
    ]

    // ponytail: unlisted currencies share one thousands scale; add a row when a market needs its own.
    nonisolated static func incomeRanges(currency: String) -> [(label: String, mid: Int)] {
        let (bounds, mids) = incomeScales[currency] ?? ([2_000, 4_000, 8_000], [1_500, 3_000, 6_000, 10_000])
        let minor = { (d: Decimal) in Money(major: d, currency).minor }
        let short = { (d: Decimal) in AmountFormat.string(minor(d), currency, short: true) }
        return [
            (String(localized: "Under \(short(bounds[0]))", table: "Onboarding"), minor(mids[0])),
            ("\(short(bounds[0])) – \(short(bounds[1]))", minor(mids[1])),
            ("\(short(bounds[1])) – \(short(bounds[2]))", minor(mids[2])),
            (String(localized: "Over \(short(bounds[2]))", table: "Onboarding"), minor(mids[3])),
        ]
    }

    /// A typed amount in the default currency, minor units: Moonee's money words ("15tr", "45k") or plain digits ("2.000.000").
    nonisolated static func amount(_ text: String, context: ParserContext) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = QuickParser.amount(in: t, context: context), a.currency == context.currency, a.amount > 0 { return a.amount }
        let digits = t.filter(\.isNumber)
        guard !digits.isEmpty, let d = Decimal(string: digits), d > 0 else { return nil }
        return Money(major: d, context.currency).minor
    }

    /// Spec §7 step 2: the declared income becomes a monthly income `Recurring` (category Salary) on payday. On payday the
    /// Budget tab asks "Received?" and records it as income split into the jars (`BudgetActions.markPaid`). Varying
    /// income is an estimate (asks for the real amount). The first payday is after today: money already received is in
    /// the wallet balances the next step asks for. One salary only: running it again updates it.
    @discardableResult
    static func saveSalary(_ amount: Int, payday: Int, regular: Bool?, now: Date = .now, calendar: Calendar = .current,
                           in context: ModelContext) -> Recurring? {
        guard amount > 0 else { return nil }
        let salary = ((try? context.fetch(FetchDescriptor<Category>())) ?? []).first { $0.key == "category.salary" }
        let existing = ((try? context.fetch(FetchDescriptor<Recurring>())) ?? []).first { $0.isIncome && $0.category == salary }
        let day = min(max(payday, 1), 31)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let r = existing ?? Recurring(name: salary?.name ?? String(localized: "Salary", table: "Onboarding"), amount: amount, nextDue: now)
        if existing == nil { context.insert(r) }
        r.amount = amount
        r.isEstimate = regular == false
        r.dueDay = day
        r.nextDue = BudgetActions.nextDate(day: day, from: tomorrow, calendar: calendar)
        r.remindDaysBefore = 0
        r.category = salary
        return r
    }

    // MARK: Wallets

    struct WalletDraft: Equatable {
        var type: WalletType
        var name: String
        /// Opening balance, minor units. For a credit card: what is owed now (stored negative).
        var amount: Int
    }

    /// Saves the wallets the user ticked. An unused wallet of the same type (the seeded cash wallet) is reused, never duplicated.
    @discardableResult
    static func saveWallets(_ drafts: [WalletDraft], in context: ModelContext) -> [Wallet] {
        var unused = ((try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.order)]))) ?? []).filter { ($0.txns ?? []).isEmpty }
        var order = (((try? context.fetch(FetchDescriptor<Wallet>())) ?? []).map(\.order).max() ?? -1) + 1
        return drafts.map { d in
            let opening = d.type == .credit ? -abs(d.amount) : d.amount
            let name = d.name.trimmingCharacters(in: .whitespaces)
            if let i = unused.firstIndex(where: { $0.type == d.type }) {
                let w = unused.remove(at: i)
                w.initialBalance = opening
                if !name.isEmpty { w.name = name }
                return w
            }
            let w = Wallet(name: name.isEmpty ? d.type.title : name, type: d.type, initialBalance: opening, order: order)
            order += 1
            context.insert(w)
            return w
        }
    }

    // MARK: Bills

    struct BillDraft: Identifiable {
        let id = UUID()
        var name: String
        var amount: Int
        /// Day of month it is due, 1–31.
        var day: Int
        var categoryKey = "category.housing"
        var symbol = "doc.text.fill"
    }

    /// Common fixed bills offered as chips.
    nonisolated static var billSuggestions: [BillDraft] {
        [
            .init(name: String(localized: "Rent", table: "Onboarding"), amount: 0, day: 5, symbol: "house.fill"),
            .init(name: String(localized: "Electricity", table: "Onboarding"), amount: 0, day: 10, symbol: "bolt.fill"),
            .init(name: String(localized: "Water", table: "Onboarding"), amount: 0, day: 10, symbol: "drop.fill"),
            .init(name: String(localized: "Internet", table: "Onboarding"), amount: 0, day: 15, symbol: "wifi"),
            .init(name: String(localized: "Phone", table: "Onboarding"), amount: 0, day: 15, symbol: "iphone"),
            .init(name: String(localized: "Subscriptions", table: "Onboarding"), amount: 0, day: 1,
                  categoryKey: "category.entertainment", symbol: "play.rectangle.fill"),
        ]
    }

    /// One monthly `Recurring` per bill with an amount, due next on its day, paid from the first non-card wallet.
    /// Reminders pick them up on save.
    @discardableResult
    static func saveBills(_ drafts: [BillDraft], now: Date = .now, calendar: Calendar = .current, in context: ModelContext) -> [Recurring] {
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let wallet = ((try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.order)]))) ?? []).first { $0.type != .credit }
        return drafts.filter { $0.amount > 0 && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.map { d in
            let r = Recurring(name: d.name.trimmingCharacters(in: .whitespaces), amount: d.amount,
                              nextDue: BudgetActions.nextDate(day: min(max(d.day, 1), 31), from: now, calendar: calendar))
            context.insert(r)
            r.category = categories.first { $0.key == d.categoryKey }
            r.wallet = wallet
            return r
        }
    }

    // MARK: Jars

    /// Spec §7 step 5: start from the jars' current percents (the 6-jar rule) and adjust to what the user said.
    /// Irregular income moves 5% from Play to Savings. When bills are a big share of income, Essentials rises to
    /// bills + 15% (rounded up to 5, at most 80), taken from Play, Growth, Investing, then Savings, none below 5%. Sums to 100.
    nonisolated static func proposePercents(keys: [String?], current: [Int], monthlyIncome: Int?, regular: Bool?, billsTotal: Int) -> [Int] {
        var p = current
        func take(_ amount: Int, from order: [String]) -> Int {
            var left = amount
            for key in order {
                guard let i = keys.firstIndex(of: key), left > 0 else { continue }
                let cut = min(left, max(p[i] - 5, 0))
                p[i] -= cut
                left -= cut
            }
            return amount - left
        }
        if regular == false, let s = keys.firstIndex(of: "jar.savings") {
            p[s] += take(5, from: ["jar.play"])
        }
        if let income = monthlyIncome, income > 0, billsTotal > 0, let e = keys.firstIndex(of: "jar.essentials") {
            let share = Int((Double(billsTotal) * 100 / Double(income)).rounded(.up))
            let target = min(80, (share + 15 + 4) / 5 * 5)
            if target > p[e] {
                p[e] += take(target - p[e], from: ["jar.play", "jar.growth", "jar.investing", "jar.savings"])
            }
        }
        return p
    }

    /// Writes the accepted percents (must total 100). The wallets just entered stay Unallocated: existing money is
    /// split once on the Budget tab, by Moonee's plan, by percent or into one jar (spec §4.1 rule A.4; Automatic
    /// applies the plan by itself).
    static func applyJars(_ percents: [Int], to jars: [Jar], in context: ModelContext) {
        let sorted = jars.sorted { $0.order < $1.order }
        guard BudgetActions.percentsValid(percents), percents.count == sorted.count else { return }
        for (jar, p) in zip(sorted, percents) { jar.percent = p }
    }

    // MARK: AI mode

    /// Spec §7 step 6: suggest a mode from the device: a local model if one fits the RAM, else BYOK.
    nonisolated static func suggestedMode(localFits: Bool) -> AIMode {
        localFits ? .local : .byok
    }
}
