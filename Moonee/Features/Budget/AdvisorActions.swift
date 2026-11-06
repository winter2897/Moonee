import Foundation
import SwiftData
import UserNotifications

extension Prefs {
    /// String: "automatic" | "suggest" | "manual". Moonee's help level (spec §4.6), default suggest.
    static let advisorLevel = "advisor.level"
    /// [String: Int]: times each advice kind was dismissed; 2 = muted until reset.
    static let advisorDismissed = "advisor.dismissed"
    /// [String]: "yyyy-MM-dd|<advice id>" handled today (agreed, dismissed or done automatically).
    static let advisorHandled = "advisor.handled"
    /// Data: JSON `[AdvisorMemory.AutoRecord]`, what Automatic did (Undo).
    static let advisorAuto = "advisor.auto"
    /// Int, bumped on every change above so views using `@AppStorage` refresh.
    static let advisorVersion = "advisor.version"
}

extension BudgetAdvisor: Equatable {
    static func == (a: Self, b: Self) -> Bool { a.input == b.input }
}

extension BudgetAdvisor.Input: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.jars == b.jars && a.budgetBalance == b.budgetBalance && a.unallocated == b.unallocated && a.bills == b.bills
            && a.cards == b.cards && a.income == b.income && a.history == b.history && a.now == b.now && a.level == b.level && a.muted == b.muted
    }

    /// The advisor's view of the stored books (jar ids are `Jar.parserKey`; bills, cards, incomes use `ref`).
    @MainActor init(txns: [Txn], wallets: [Wallet], jars: [Jar], recurrings: [Recurring], ledger: Ledger<PersistentIdentifier>,
                    now: Date, calendar: Calendar, level: AdvisorLevel, muted: Set<BudgetAdvisor.Kind>) {
        let month = calendar.dateInterval(of: .month, for: now)!
        let sorted = jars.sorted { $0.order < $1.order }
        let history: [BudgetAdvisor.PastMonth] = (1...3).compactMap { back in
            guard let start = calendar.date(byAdding: .month, value: -back, to: month.start),
                  let m = calendar.dateInterval(of: .month, for: start) else { return nil }
            let spent = Dictionary(sorted.map { ($0.parserKey, ledger.jarMonth($0.persistentModelID, in: m).spent) }, uniquingKeysWith: +)
            let income = ledger.income(in: m)
            return income > 0 || spent.values.contains { $0 > 0 } ? .init(income: income, spent: spent) : nil
        }
        let income = recurrings.filter(\.isIncome).map { r -> BudgetAdvisor.Income in
            let received = BudgetActions.isReceived(r, txns: txns, calendar: calendar)
            let due = received ? BudgetActions.nextDue(after: r.nextDue, r.frequency, day: r.dueDay, calendar: calendar) : r.nextDue
            return .init(id: r.ref, name: r.name, amount: r.amount, due: due,
                         next: BudgetActions.nextDue(after: due, r.frequency, day: r.dueDay, calendar: calendar), isEstimate: r.isEstimate)
        }.min { $0.due < $1.due }
        self.init(
            jars: sorted.map { j in
                let m = ledger.jarMonth(j.persistentModelID, in: month)
                return .init(id: j.parserKey, name: j.name, role: .init(key: j.key), percent: j.percent,
                             balance: ledger.jarBalance(j.persistentModelID), spent: m.spent, budget: m.budget)
            },
            budgetBalance: ledger.budgetBalance, unallocated: ledger.unallocated,
            bills: recurrings.filter { !$0.isIncome }.map {
                .init(id: $0.ref, name: $0.name, amount: $0.amount, due: $0.nextDue, frequency: $0.frequency,
                      essential: $0.category?.jar.map { $0.key == "jar.essentials" } ?? true)
            },
            cards: wallets.filter { $0.type == .credit && $0.inBudget }.compactMap { w in
                let owed = -ledger.walletBalance(w.persistentModelID)
                guard owed > 0, let day = w.dueDay else { return nil }
                return .init(id: w.ref, name: w.name, owed: owed, due: BudgetActions.nextDate(day: day, from: now, calendar: calendar))
            },
            income: income, history: history, now: now, calendar: calendar, level: level, muted: muted)
    }
}

extension PersistentModel {
    /// Identifies a bill, card or income in an `Advice`: the object in this context (a context keeps one instance per
    /// record). Never stored. Not `persistentModelID`'s text: unsaved records can print alike.
    var ref: String { "\(ObjectIdentifier(self))" }
}

/// What the user did with Moonee's advice: muted kinds, the day's cap, what Automatic did (spec §4.6).
enum AdvisorMemory {
    /// Suggestions a day (warnings always show).
    static let dailyCap = 2

    struct AutoRecord: Codable, Equatable, Identifiable {
        /// `Txn.externalID` of every txn it wrote.
        var tag: String
        var kind: String
        var title: String
        var text: String
        var date: Date
        /// payday: the salary's due date before it moved on, restored by Undo.
        var previousDue: Date?
        var id: String { tag }
    }

    private static var defaults: UserDefaults { .standard }
    private static func bump() { defaults.set(defaults.integer(forKey: Prefs.advisorVersion) + 1, forKey: Prefs.advisorVersion) }

    static var muted: Set<BudgetAdvisor.Kind> {
        let counts = defaults.dictionary(forKey: Prefs.advisorDismissed) as? [String: Int] ?? [:]
        return Set(counts.filter { $0.value >= 2 }.compactMap { BudgetAdvisor.Kind(rawValue: $0.key) })
    }

    private static func dayTag(_ now: Date) -> String { now.formatted(.iso8601.year().month().day()) }

    static func handledToday(now: Date = .now) -> [String] {
        let tag = dayTag(now) + "|"
        return (defaults.stringArray(forKey: Prefs.advisorHandled) ?? []).filter { $0.hasPrefix(tag) }.map { String($0.dropFirst(tag.count)) }
    }

    /// Agreed, kept, or done automatically: not shown again today.
    static func handle(_ a: BudgetAdvisor.Advice, now: Date = .now) {
        defaults.set((defaults.stringArray(forKey: Prefs.advisorHandled) ?? []).filter { $0.hasPrefix(dayTag(now)) } + ["\(dayTag(now))|\(a.id)"],
                     forKey: Prefs.advisorHandled)
        bump()
    }

    /// "Skip": twice for the same kind and Moonee stops suggesting it.
    static func dismiss(_ a: BudgetAdvisor.Advice, now: Date = .now) {
        var counts = defaults.dictionary(forKey: Prefs.advisorDismissed) as? [String: Int] ?? [:]
        counts[a.kind.rawValue, default: 0] += 1
        defaults.set(counts, forKey: Prefs.advisorDismissed)
        handle(a, now: now)
    }

    static func resetLearning() {
        defaults.removeObject(forKey: Prefs.advisorDismissed)
        defaults.removeObject(forKey: Prefs.advisorHandled)
        bump()
    }

    /// The one card to show: not handled today; after the day's 2 suggestions only warnings.
    static func pick(_ advice: [BudgetAdvisor.Advice], now: Date = .now) -> BudgetAdvisor.Advice? {
        let handled = handledToday(now: now)
        return advice.first { !handled.contains($0.id) && ($0.kind.isWarning || handled.count < dailyCap) }
    }

    static var autoRecords: [AutoRecord] {
        defaults.data(forKey: Prefs.advisorAuto).flatMap { try? JSONDecoder().decode([AutoRecord].self, from: $0) } ?? []
    }

    static func setAutoRecords(_ records: [AutoRecord]) {
        defaults.set(try? JSONEncoder().encode(records), forKey: Prefs.advisorAuto)
        bump()
    }
}

extension BudgetActions {
    /// Applies an advice's numbers. Returns the txns written (Automatic tags them for Undo).
    @discardableResult
    static func apply(_ a: BudgetAdvisor.Advice, date: Date = .now, in context: ModelContext, calendar: Calendar = .current) -> [Txn] {
        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let jar = { (id: String?) in id.flatMap { id in jars.first { $0.parserKey == id } } }
        switch a.kind {
        case .payday:
            guard let r = ((try? context.fetch(FetchDescriptor<Recurring>())) ?? []).first(where: { $0.ref == a.ref }) else { return [] }
            return [markPaid(r, amount: a.amount, date: date, jars: jars, splits: shares(a.moves, jars), in: context, calendar: calendar)]
        case .unallocated, .negativeJar, .monthEnd:
            var out: [Txn] = []
            let fromUnallocated = a.moves.filter { $0.from == nil }
            if let t = allocate(shares(fromUnallocated, jars), date: date, in: context) { out.append(t) }
            for m in a.moves where m.from != nil {
                guard let from = jar(m.from) else { continue }
                let t = Txn(amount: m.amount, kind: .jarTransfer, date: date, note: loc("Moonee's plan"))
                context.insert(t)
                t.jar = from
                t.toJar = jar(m.to) // nil: back to Unallocated
                out.append(t)
            }
            return out
        case .rebalance:
            for j in jars { if let p = a.percents[j.parserKey] { j.percent = p } }
            return []
        case .noMoney, .cardDue, .billDue, .pace:
            return []
        }
    }

    private static func shares(_ moves: [BudgetAdvisor.Move], _ jars: [Jar]) -> [Jar: Int] {
        Dictionary(moves.compactMap { m in m.to.flatMap { id in jars.first { $0.parserKey == id } }.map { ($0, m.amount) } }, uniquingKeysWith: +)
    }

    /// Unallocated money into jars by an explicit plan (one jarTransfer with a split per jar).
    @discardableResult
    static func allocate(_ shares: [Jar: Int], note: String = loc("Moonee's plan"), date: Date = .now, in context: ModelContext) -> Txn? {
        let total = shares.values.reduce(0, +)
        guard total > 0 else { return nil }
        let t = Txn(amount: total, kind: .jarTransfer, date: date, note: note)
        context.insert(t)
        for (jar, amount) in shares where amount > 0 {
            let s = IncomeSplit(amount: amount, jar: jar)
            context.insert(s)
            s.txn = t
        }
        return t
    }

    /// "Received" on an income recurring: split by Moonee's plan (Automatic / Suggest) or by percent (Do it myself).
    @discardableResult
    static func receive(_ r: Recurring, amount: Int? = nil, date: Date = .now, level: AdvisorLevel = .current, in context: ModelContext,
                        calendar: Calendar = .current) -> Txn {
        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        var splits: [Jar: Int]?
        if level != .manual {
            let advisor = BudgetFacts(context, now: date, calendar: calendar).advisor
            let next = nextDue(after: r.nextDue, r.frequency, day: r.dueDay, calendar: calendar)
            splits = shares(advisor.plan(amount ?? r.amount, until: next).moves, jars)
        }
        return markPaid(r, amount: amount, date: date, jars: jars, splits: splits, in: context, calendar: calendar)
    }

    /// Spec §4.2 rule A.5: buying an asset or putting money into an off-budget wallet takes it out of `jar`
    /// (a transfer with a jar). The asset gains `quantity` at the price paid.
    @discardableResult
    static func setAside(_ amount: Int, from wallet: Wallet, jar: Jar, into target: Wallet? = nil, asset: Asset? = nil, quantity: Double = 0,
                         date: Date = .now, in context: ModelContext) -> Txn {
        let t = Txn(amount: amount, kind: .transfer, currencyCode: wallet.currencyCode, date: date,
                    note: asset.map { String(localized: "Bought \($0.symbol)", table: "Budget") } ?? target?.name ?? "", wallet: wallet)
        context.insert(t)
        t.toWallet = target
        t.jar = jar
        if let asset {
            if quantity > 0 {
                asset.quantity += quantity
                asset.unitPrice = Int((Double(amount) / quantity).rounded())
            }
            asset.costBasis = (asset.costBasis ?? 0) + amount
            asset.updatedAt = date
        }
        return t
    }

    /// Selling an asset or taking money out of an off-budget wallet: it lands in a budget wallet as Unallocated.
    @discardableResult
    static func bringBack(_ amount: Int, into wallet: Wallet, from source: Wallet? = nil, asset: Asset? = nil, quantity: Double = 0,
                          date: Date = .now, in context: ModelContext) -> Txn {
        let t = Txn(amount: amount, kind: .transfer, currencyCode: wallet.currencyCode, date: date,
                    note: asset.map { String(localized: "Sold \($0.symbol)", table: "Budget") } ?? source?.name ?? "", wallet: source)
        context.insert(t)
        t.toWallet = wallet
        if let asset, quantity > 0 {
            let sold = min(quantity, asset.quantity)
            if asset.quantity > 0, let cost = asset.costBasis { asset.costBasis = cost - Int(Double(cost) * sold / asset.quantity) }
            asset.quantity -= sold
            asset.unitPrice = Int((Double(amount) / quantity).rounded())
            asset.updatedAt = date
        }
        return t
    }
}

/// "Automatic" (spec §4.6): records the salary on payday and applies Moonee's plans, then says so with Undo.
/// Runs with the reminder refresh (app active, after saves), one action per run.
@MainActor enum Autopilot {
    static let auto: Set<BudgetAdvisor.Kind> = [.payday, .unallocated, .negativeJar]

    @discardableResult
    static func run(_ context: ModelContext, now: Date = .now, calendar: Calendar = .current, notify: Bool = true) -> AdvisorMemory.AutoRecord? {
        guard AdvisorLevel.current == .automatic else { return nil }
        let handled = AdvisorMemory.handledToday(now: now)
        let facts = BudgetFacts(context, now: now, calendar: calendar)
        guard let a = facts.advice.first(where: { auto.contains($0.kind) && !handled.contains($0.id) && !$0.moves.isEmpty }),
              !(a.kind == .payday && facts.advisor.input.income?.isEstimate == true) else { return nil }
        let previousDue = a.kind == .payday ? facts.advisor.input.income?.due : nil
        let txns = BudgetActions.apply(a, date: now, in: context, calendar: calendar)
        guard !txns.isEmpty else { return nil }
        let tag = "auto:\(a.id).\(Int(now.timeIntervalSince1970))"
        txns.forEach { $0.externalID = tag }
        let title = a.kind == .payday ? String(localized: "Moonee recorded \(facts.advisor.input.income?.name ?? "")", table: "Budget")
                                      : loc("Moonee moved your money")
        let record = AdvisorMemory.AutoRecord(tag: tag, kind: a.kind.rawValue, title: title, text: a.text, date: now, previousDue: previousDue)
        AdvisorMemory.setAutoRecords(Array((AdvisorMemory.autoRecords + [record]).suffix(5)))
        AdvisorMemory.handle(a, now: now)
        if notify {
            let content = UNMutableNotificationContent()
            (content.title, content.body) = (title, a.text)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(Reminders.prefix)\(tag)", content: content,
                                                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
        }
        return record
    }

    /// Undo: deletes what it wrote and puts the salary back on its payday.
    static func undo(_ record: AdvisorMemory.AutoRecord, in context: ModelContext) {
        let tag: String? = record.tag
        let txns = (try? context.fetch(FetchDescriptor<Txn>(predicate: #Predicate { $0.externalID == tag }))) ?? []
        if let due = record.previousDue, let category = txns.first(where: { $0.kind == .income })?.category {
            for r in (try? context.fetch(FetchDescriptor<Recurring>())) ?? [] where r.isIncome && r.category == category { r.nextDue = due }
        }
        txns.forEach(context.delete)
        AdvisorMemory.setAutoRecords(AdvisorMemory.autoRecords.filter { $0.tag != record.tag })
    }

    /// "OK": hides the record (the money stays).
    static func acknowledge(_ record: AdvisorMemory.AutoRecord) {
        AdvisorMemory.setAutoRecords(AdvisorMemory.autoRecords.filter { $0.tag != record.tag })
    }
}
