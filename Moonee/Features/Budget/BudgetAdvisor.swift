import Foundation

/// Spec §4.6 "Moonee's help level", stored in `Prefs.advisorLevel`.
enum AdvisorLevel: String, CaseIterable, Identifiable, Sendable {
    /// Moonee records the salary on payday and applies its plans, then says what it did (Undo, edit the amount).
    case automatic
    /// Default: Moonee proposes a plan with numbers and why; nothing moves until the user agrees.
    case suggest
    /// No suggestions, only warnings (a jar below zero, empty wallets, a bill due).
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: loc("Automatic")
        case .suggest: loc("Suggest")
        case .manual: loc("Do it myself")
        }
    }

    var summary: String {
        switch self {
        case .automatic: loc("Moonee records your salary on payday and splits money by its plan, then tells you. You can undo.")
        case .suggest: loc("Moonee proposes a plan with the numbers and why. Nothing moves until you agree.")
        case .manual: loc("No suggestions, only warnings: a jar below zero or a bill due.")
        }
    }

    static var current: AdvisorLevel { UserDefaults.standard.string(forKey: Prefs.advisorLevel).flatMap(Self.init) ?? .suggest }
}

/// Moonee as someone who knows personal finance (spec §4.6). Pure: every number is computed here and unit-tested.
/// The text is a template the Budget card, notifications and chat show as is; a model may only rephrase it.
struct BudgetAdvisor: Sendable {
    /// Default jars by key; user-made jars are `.other`.
    enum Role: Sendable {
        case essentials, savings, investing, play, growth, giving, other

        init(key: String?) {
            self = switch key {
            case "jar.essentials": .essentials
            case "jar.savings": .savings
            case "jar.investing": .investing
            case "jar.play": .play
            case "jar.growth": .growth
            case "jar.giving": .giving
            default: .other
            }
        }

        /// Money kept for later: taken from last, never "going too fast".
        var isReserve: Bool { self == .savings || self == .investing }
    }

    struct Jar: Sendable, Equatable {
        var id: String
        var name: String
        var role: Role
        var percent: Int
        var balance: Int
        /// This month.
        var spent = 0
        var budget = 0
    }

    struct Bill: Sendable, Equatable {
        var id = ""
        var name: String
        var amount: Int
        var due: Date
        var frequency = Frequency.monthly
        /// Paid from Essentials (its category's jar, or none).
        var essential = true
    }

    struct Card: Sendable, Equatable {
        var id = ""
        var name: String
        /// What the card owes now (positive).
        var owed: Int
        var due: Date
    }

    /// The next salary (or other income recurring) not received yet.
    struct Income: Sendable, Equatable {
        var id = ""
        var name: String
        var amount: Int
        var due: Date
        /// The payday after `due`.
        var next: Date
        var isEstimate = false
    }

    /// A finished month: income and what each jar spent.
    struct PastMonth: Sendable, Equatable {
        var income: Int
        var spent: [String: Int]
    }

    struct Input: Sendable {
        var jars: [Jar]
        /// Σ wallets that count in the budget (= Σ jars + unallocated).
        var budgetBalance: Int
        var unallocated: Int
        var bills: [Bill] = []
        var cards: [Card] = []
        var income: Income?
        /// Up to 3 finished months, newest first.
        var history: [PastMonth] = []
        var now: Date
        var currency = Money.defaultCurrency
        var calendar = Calendar.current
        var locale = Locale.autoupdatingCurrent
        var level = AdvisorLevel.suggest
        /// Kinds the user dismissed twice (spec §4.6 learning).
        var muted: Set<Kind> = []
    }

    /// Priority order: the first one is the card shown.
    enum Kind: String, CaseIterable, Sendable {
        case payday, noMoney, negativeJar, cardDue, unallocated, billDue, pace, monthEnd, rebalance

        /// Shown even after the day's 2 suggestions, and in "Do it myself".
        var isWarning: Bool { [.payday, .noMoney, .negativeJar, .cardDue, .billDue].contains(self) }
    }

    /// Jar money to move. `from` nil = Unallocated (or the incoming salary); `to` nil = back to Unallocated.
    struct Move: Sendable, Equatable {
        var from: String?
        var to: String?
        var amount: Int
    }

    struct Advice: Sendable, Equatable, Identifiable {
        var kind: Kind
        var title: String
        var text: String
        /// One line of "why".
        var why: String?
        var moves: [Move] = []
        /// rebalance: the new percent per jar id.
        var percents: [String: Int] = [:]
        /// The income, bill, card or jar it is about.
        var ref: String?
        var amount = 0
        var id: String { "\(kind.rawValue).\(ref ?? "")" }
    }

    /// Where new money goes (moment 1, payday): a. Essentials until the next payday, b. jars below zero,
    /// c. the emergency fund, d. the rest by percent.
    struct Plan: Sendable, Equatable {
        var shares: [String: Int] = [:]
        /// Stays unallocated: covers what the jars already promised beyond the wallets.
        var kept = 0
        var bills = 0
        var spending = 0
        var until: Date
        var refill = 0
        var emergency = 0
        var emergencyTarget = 0
        var byPercent = 0

        var moves: [Move] { shares.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { Move(from: nil, to: $0.key, amount: $0.value) } }
    }

    /// Months of essential spending the emergency fund should hold (3–6; Moonee starts with 3).
    static let emergencyMonths = 3
    // ponytail: half of what is left after a–b goes to the fund until it is full; tune if users find it too strict.
    static let emergencyShare = 2

    let input: Input
    init(_ input: Input) { self.input = input }

    var essentials: Jar? { input.jars.first { $0.role == .essentials } }
    var savings: Jar? { input.jars.first { $0.role == .savings } }

    /// A normal month of essential spending: the average of finished months, else Essentials' percent of the income.
    var essentialMonthly: Int {
        let past = input.history.compactMap { m in essentials.flatMap { m.spent[$0.id] } }.filter { $0 > 0 }
        if !past.isEmpty { return past.reduce(0, +) / past.count }
        let incomes = input.history.map(\.income).filter { $0 > 0 }
        let income = input.income?.amount ?? (incomes.isEmpty ? 0 : incomes.reduce(0, +) / incomes.count)
        return income * (essentials?.percent ?? 0) / 100
    }

    var emergencyTarget: Int { Self.emergencyMonths * essentialMonthly }

    /// Essential bills in a month, whatever their frequency.
    // ponytail: a weekly bill counts once in "bills until payday"; enough for monthly rent/power/phone bills.
    private var monthlyEssentialBills: Int {
        input.bills.filter(\.essential).reduce(0) { sum, b in
            sum + {
                switch b.frequency {
                case .daily: b.amount * 30
                case .weekly: b.amount * 52 / 12
                case .monthly: b.amount
                case .yearly: b.amount / 12
                }
            }()
        }
    }

    private var today: Date { input.calendar.startOfDay(for: input.now) }
    private func days(to date: Date) -> Int {
        input.calendar.dateComponents([.day], from: today, to: input.calendar.startOfDay(for: date)).day ?? 0
    }

    func plan(_ amount: Int, until: Date) -> Plan {
        var p = Plan(until: until)
        var rest = amount
        @discardableResult func give(_ id: String, _ want: Int) -> Int {
            let a = min(max(want, 0), rest)
            if a > 0 { p.shares[id, default: 0] += a; rest -= a }
            return a
        }
        p.kept = min(rest, max(-input.unallocated, 0))
        rest -= p.kept
        if let e = essentials {
            p.bills = input.bills.filter { $0.essential && $0.due < until }.reduce(0) { $0 + $1.amount }
            p.spending = max(essentialMonthly - monthlyEssentialBills, 0) * max(days(to: until), 1) / 30
            give(e.id, p.bills + p.spending - e.balance) // a negative Essentials is refilled too
        }
        for j in input.jars where j.role != .essentials && j.balance < 0 { p.refill += give(j.id, -j.balance) }
        if let s = savings, emergencyTarget > s.balance {
            p.emergencyTarget = emergencyTarget
            p.emergency = give(s.id, min(emergencyTarget - s.balance, rest / Self.emergencyShare))
        }
        let split = Ledger<String>.split(rest, by: input.jars.map { ($0.id, $0.percent) })
        if split.isEmpty { p.kept += rest } else { p.byPercent = rest }
        for (id, a) in split { p.shares[id, default: 0] += a }
        p.shares = clean(p.shares)
        return p
    }

    /// A clean step for an amount: VND/LAK 10k under 1tr, 50k under 10tr, 100k above; other currencies two leading
    /// digits (881.95 → 10, 7,240 → 100).
    func step(_ amount: Int) -> Int {
        let unit = Int(pow(10, Double(AmountFormat.fractionDigits(input.currency))))
        let major = max(abs(amount) / unit, 1)
        if ["VND", "LAK"].contains(input.currency) {
            return (major < 1_000_000 ? 10_000 : major < 10_000_000 ? 50_000 : 100_000) * unit
        }
        return max(Int(pow(10, floor(log10(Double(major))) - 1)), 1) * unit
    }

    /// Rounds down to a clean step, a finer one when the amount is smaller than the step (a daily allowance).
    func roundDown(_ amount: Int) -> Int {
        var st = step(amount)
        while st > 1, amount < st { st /= 10 }
        return amount / st * st
    }

    /// Rounds each jar's share up to a clean step (so a need or a refill is never short) and lets Savings (or the last
    /// jar with a share) absorb the difference, so the plan still adds up exactly. Too small to round: unchanged.
    func clean(_ shares: [String: Int]) -> [String: Int] {
        let order = input.jars.map(\.id).filter { shares[$0, default: 0] > 0 }
        guard let sink = savings.map(\.id).flatMap({ order.contains($0) ? $0 : nil }) ?? order.last else { return shares }
        var out = shares
        for id in order where id != sink {
            let a = shares[id]!, st = step(a)
            out[id] = (a + st - 1) / st * st
        }
        out[sink] = shares.values.reduce(0, +) - out.filter { $0.key != sink }.values.reduce(0, +)
        return out[sink]! >= 0 ? out : shares
    }

    /// Money to cover a jar below zero (`target`) or the jars' promise beyond the wallets (`target` nil), in order:
    /// Play → Growth → Giving → your own jars → Unallocated → Savings / Investing last.
    func cover(_ need: Int, for target: String?) -> (moves: [Move], fromReserve: Bool, missing: Int) {
        let order: [Role] = [.play, .growth, .giving, .other]
        var sources: [(id: String?, available: Int, reserve: Bool)] = order.flatMap { role in
            input.jars.filter { $0.role == role && $0.id != target }.map { ($0.id, $0.balance, false) }
        }
        if target != nil { sources.append((nil, input.unallocated, false)) }
        sources += input.jars.filter { $0.role.isReserve && $0.id != target }.sorted { $0.role == .savings && $1.role != .savings }
            .map { ($0.id, $0.balance, true) }
        var left = need, moves: [Move] = [], reserve = false
        for s in sources where left > 0 && s.available > 0 {
            // A clean amount when the source has it, else exactly what is needed (or all it has).
            let st = step(left), rounded = (left + st - 1) / st * st, a = rounded <= s.available ? rounded : min(left, s.available)
            moves.append(Move(from: s.id, to: target, amount: a))
            reserve = reserve || s.reserve
            left -= a
        }
        return (moves, reserve, max(left, 0))
    }

    /// Every piece of advice that applies now, most urgent first, for the level and without muted kinds.
    var advice: [Advice] {
        var out: [Advice] = []
        let tomorrow = input.calendar.date(byAdding: .day, value: 1, to: today)!
        let negative = input.jars.filter { $0.balance < 0 }.min { $0.balance < $1.balance }

        if let inc = input.income, inc.due < tomorrow {
            let p = plan(inc.amount, until: inc.next)
            out.append(Advice(kind: .payday, title: String(localized: "\(inc.name) \(money(inc.amount)) in yet?", table: "Budget"),
                              text: suggestion(p), why: why(p), moves: p.moves, ref: inc.id, amount: inc.amount))
        }

        if input.budgetBalance <= 0, negative != nil || input.unallocated < 0 {
            var text = negative.map { String(localized: "\($0.name) is \(money(-$0.balance)) below zero, and your budget wallets hold \(money(input.budgetBalance)).", table: "Budget") }
                ?? String(localized: "Your jars hold more than your budget wallets (\(money(input.budgetBalance))).", table: "Budget")
            text += " " + (input.income.map { String(localized: "Update a wallet's balance if it holds more, or record \($0.name) early if it's in.", table: "Budget") }
                           ?? loc("Update a wallet's balance if it holds more."))
            out.append(Advice(kind: .noMoney, title: loc("Your wallets have no money yet"), text: text, ref: input.income?.id))
        } else if let n = negative, case let c = cover(-n.balance, for: n.id),
                  !(input.unallocated > 0 && c.moves.allSatisfy { $0.from == nil }) { // else the Unallocated plan refills it
            var a = Advice(kind: .negativeJar, title: String(localized: "\(n.name) is \(money(-n.balance)) below zero", table: "Budget"),
                           text: "", moves: c.moves, ref: n.id, amount: -n.balance)
            if c.moves.isEmpty {
                a.text = loc("No other jar has money left. Add income or update a wallet's balance.")
            } else {
                a.text = String(localized: "Move \(movesText(c.moves)).", table: "Budget")
                if c.fromReserve { a.why = loc("Savings and Investing come last: the other jars are empty.") }
                if c.missing > 0 { a.text += " " + String(localized: "\(money(c.missing)) is still missing.", table: "Budget") }
            }
            out.append(a)
        }

        let soon = input.calendar.date(byAdding: .day, value: 6, to: today)!
        if let card = input.cards.filter({ $0.owed > 0 && $0.due < soon }).min(by: { $0.due < $1.due }) {
            out.append(Advice(kind: .cardDue, title: String(localized: "\(card.name) is due \(day(card.due))", table: "Budget"),
                              text: String(localized: "Pay the full \(money(card.owed)) so no interest is charged.", table: "Budget"),
                              why: loc("Your jars already paid for these swipes, so paying the card moves no jar money."),
                              ref: card.id, amount: card.owed))
        }

        if input.unallocated > 0 {
            let until = input.income.map { $0.due > input.now ? $0.due : $0.next }
                ?? input.calendar.dateInterval(of: .month, for: input.now)!.end
            let p = plan(input.unallocated, until: until)
            out.append(Advice(kind: .unallocated, title: String(localized: "\(money(input.unallocated)) isn't in a jar yet", table: "Budget"),
                              text: suggestion(p), why: why(p), moves: p.moves, amount: input.unallocated))
        } else if input.unallocated < 0, input.budgetBalance > 0 {
            let c = cover(-input.unallocated, for: nil)
            var a = Advice(kind: .unallocated, title: String(localized: "Your jars hold \(money(-input.unallocated)) more than your wallets", table: "Budget"),
                           text: String(localized: "Take \(movesText(c.moves)) so the jars match your wallets.", table: "Budget"),
                           moves: c.moves, amount: input.unallocated)
            if c.fromReserve { a.why = loc("Savings and Investing come last: the other jars are empty.") }
            if !c.moves.isEmpty { out.append(a) }
        }

        if let b = input.bills.filter({ $0.due < input.calendar.date(byAdding: .day, value: 2, to: today)! }).min(by: { $0.due < $1.due }) {
            out.append(Advice(kind: .billDue, title: String(localized: "\(b.name) is due \(day(b.due))", table: "Budget"),
                              text: String(localized: "\(money(b.amount)). Mark it paid once it's done.", table: "Budget"), ref: b.id, amount: b.amount))
        }

        let month = input.calendar.dateInterval(of: .month, for: input.now)!
        let monthDays = input.calendar.range(of: .day, in: .month, for: input.now)?.count ?? 30
        let daysLeft = max(days(to: month.end), 1) // today included
        let gone = Double(monthDays - daysLeft + 1) / Double(monthDays)
        let fast = input.jars.filter { !$0.role.isReserve && $0.budget > 0 && $0.balance > 0 }
            .map { ($0, Double($0.spent) / Double($0.budget)) }
            .filter { $0.1 >= 0.5 && $0.1 - gone >= 0.3 }
            .max { $0.1 - gone < $1.1 - gone }
        if let (j, used) = fast, case let raw = j.balance / daysLeft, case let daily = roundDown(raw) {
            out.append(Advice(kind: .pace, title: String(localized: "\(j.name) is going fast", table: "Budget"),
                              text: String(localized: "\(Int((used * 100).rounded()))% spent with \(Int((gone * 100).rounded()))% of the month gone. Keep to about \(money(daily)) a day until the month ends.", table: "Budget"),
                              ref: j.id, amount: daily))
        }

        if daysLeft <= 3, let play = input.jars.first(where: { $0.role == .play && $0.balance > 0 }), let s = savings {
            out.append(Advice(kind: .monthEnd, title: String(localized: "\(money(play.balance)) left in \(play.name)", table: "Budget"),
                              text: String(localized: "Keep it for next month, or move it to \(s.name)?", table: "Budget"),
                              moves: [Move(from: play.id, to: s.id, amount: play.balance)], ref: play.id, amount: play.balance))
        }

        if let r = rebalance() { out.append(r) }

        return out.filter { !input.muted.contains($0.kind) }.compactMap { a in
            guard input.level == .manual else { return a }
            switch a.kind {
            case .noMoney, .billDue, .cardDue: return a
            case .negativeJar:
                var w = a
                w.moves = []
                w.why = nil
                w.text = loc("Move money in from another jar when you can.")
                return w
            default: return nil
            }
        }
    }

    /// Moment 6: after 2–3 finished months, Essentials' real share of income vs its percent. Moves the gap (in steps
    /// of 5%) from or to Play, then Growth.
    func rebalance() -> Advice? {
        let months = input.history.filter { $0.income > 0 }
        guard months.count >= 2, let e = essentials else { return nil }
        let income = months.reduce(0) { $0 + $1.income }, spent = months.reduce(0) { $0 + ($1.spent[e.id] ?? 0) }
        let actual = Int((Double(spent) * 100 / Double(income)).rounded())
        let proposed = min(max(Int((Double(actual) / 5).rounded()) * 5, 30), 80)
        var delta = proposed - e.percent
        guard abs(delta) >= 5 else { return nil }
        var percents = [e.id: proposed]
        for role in [Role.play, .growth] {
            guard delta != 0, let j = input.jars.first(where: { $0.role == role }) else { continue }
            let take = delta > 0 ? min(delta, j.percent) : delta
            percents[j.id] = j.percent - take
            delta -= take
        }
        guard delta == 0 else { return nil }
        let names = input.jars.compactMap { j in percents[j.id].map { "\(j.name) \($0)%" } }.joined(separator: ", ")
        return Advice(kind: .rebalance, title: loc("Time to adjust your split?"),
                      text: String(localized: "The last \(months.count) months \(e.name) took \(actual)% of your income but gets \(e.percent)%. Try \(names).", table: "Budget"),
                      percents: percents)
    }

    /// Moment 7: before buying an asset or a big spend out of `jar`, is the emergency fund there?
    func emergencyNote(spending amount: Int, from jar: String?) -> String? {
        guard let s = savings, emergencyTarget > 0 else { return nil }
        let after = s.balance - (jar == s.id ? amount : 0)
        guard after < emergencyTarget else { return nil }
        return String(localized: "Your emergency fund (\(s.name)) would hold \(money(max(after, 0))) of \(money(emergencyTarget)), \(Self.emergencyMonths) months of essentials. Fill it first if you can.", table: "Budget")
    }

    // MARK: - Text

    private func money(_ minor: Int) -> String { AmountFormat.string(minor, input.currency, locale: input.locale) }
    private func short(_ minor: Int) -> String { AmountFormat.string(minor, input.currency, short: true, locale: input.locale) }
    private func day(_ date: Date) -> String { date.formatted(Date.FormatStyle(locale: input.locale, calendar: input.calendar, timeZone: input.calendar.timeZone).day().month()) }
    private func name(_ id: String?) -> String { id.flatMap { id in input.jars.first { $0.id == id }?.name } ?? loc("Unallocated") }

    /// "Essentials 2,4tr · Savings 8,8tr · …" in jar order.
    func suggestion(_ p: Plan) -> String {
        let lines = input.jars.compactMap { j in p.shares[j.id].flatMap { $0 > 0 ? "\(j.name) \(short($0))" : nil } }
        var text = String(localized: "Moonee suggests: \(lines.joined(separator: " · ")).", table: "Budget")
        if p.kept > 0 { text += " " + String(localized: "\(short(p.kept)) stays unallocated to back what the jars already hold.", table: "Budget") }
        return text
    }

    func why(_ p: Plan) -> String {
        var parts: [String] = []
        if let e = essentials, p.shares[e.id] ?? 0 > 0, p.bills + p.spending > 0 {
            parts.append(p.bills > 0 && p.spending > 0
                ? String(localized: "\(e.name) covers \(short(p.bills)) of bills and \(short(p.spending)) of everyday needs until \(day(p.until)).", table: "Budget")
                : p.bills > 0 ? String(localized: "\(e.name) covers \(short(p.bills)) of bills until \(day(p.until)).", table: "Budget")
                : String(localized: "\(e.name) covers \(short(p.spending)) of everyday needs until \(day(p.until)).", table: "Budget"))
        }
        if p.refill > 0 { parts.append(String(localized: "\(short(p.refill)) refills jars below zero.", table: "Budget")) }
        if p.emergency > 0, let s = savings {
            parts.append(String(localized: "\(s.name) builds your emergency fund toward \(short(p.emergencyTarget)), \(Self.emergencyMonths) months of essentials.", table: "Budget"))
        }
        if p.byPercent > 0 { parts.append(loc("The rest follows your percents.")) }
        return parts.joined(separator: " ")
    }

    /// "1tr from Play and 500k from Unallocated".
    private func movesText(_ moves: [Move]) -> String {
        moves.map { String(localized: "\(short($0.amount)) from \(name($0.from))", table: "Budget") }
            .formatted(.list(type: .and).locale(input.locale))
    }
}
