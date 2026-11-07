import Foundation
import SwiftData

/// One realistic sample user so every screen has data: Minh, an office worker in TP.HCM (VND, salary 25tr on the 5th),
/// with ~3 months of books up to `now` (dates are relative, so it never goes stale). Deterministic: a seeded generator.
/// Account › Data "Load sample data" (Debug and TestFlight builds), or launch with `-demoUser YES` (Debug, empty store).
/// Every write goes through the app's own writers: `allocate`, `BudgetActions.receive`/`payCard`/`setAside`/`moveBetweenJars`.
@MainActor enum DemoUser {
    /// Debug and TestFlight (sandbox receipt) builds; never App Store ones.
    static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    /// Erases everything (`DataReset.deleteAll`), then seeds Minh.
    static func load(into context: ModelContext) throws {
        try DataReset.deleteAll(context)
        seed(context)
        try context.save()
    }

    #if DEBUG
    /// `-demoUser YES` on an empty store (screenshots).
    static func seedIfRequested(_ context: ModelContext) {
        guard UserDefaults.standard.bool(forKey: "demoUser"), (try? context.fetchCount(FetchDescriptor<Txn>())) == 0 else { return }
        seed(context)
        try? context.save()
    }
    #endif

    static func seed(_ context: ModelContext, now: Date = .now, calendar cal: Calendar = .current, defaults: UserDefaults = .standard) {
        Seed.ifNeeded(context)
        let vnd = "VND"
        defaults.set(vnd, forKey: Money.currencyKey)
        defaults.set("Minh", forKey: Prefs.profileName)
        defaults.set("avatar.boy", forKey: Prefs.profileAvatar)
        defaults.set(AdvisorLevel.suggest.rawValue, forKey: Prefs.advisorLevel)
        defaults.set(true, forKey: Prefs.onboardingDone)
        defaults.set(25_000_000, forKey: Prefs.monthlyIncome)
        defaults.set(true, forKey: Prefs.incomeRegular)
        Terms.accept(defaults, now: now)

        var rng = SeededRandom(seed: 2026)
        func k(_ lo: Int, _ hi: Int) -> Int { Int.random(in: lo / 5...hi / 5, using: &rng) * 5_000 } // thousands, 5k steps
        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
        func any(_ s: [String]) -> String { s.randomElement(using: &rng)! }

        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let jar = { (key: String) in jars.first { $0.key == key }! }
        let cats = Dictionary(((try? context.fetch(FetchDescriptor<Category>())) ?? []).compactMap { c in c.key.map { ($0, c) } },
                              uniquingKeysWith: { a, _ in a })

        // Wallets: the seeded cash wallet becomes "Tiền mặt".
        let cash = ((try? context.fetch(FetchDescriptor<Wallet>())) ?? []).first { $0.type == .cash } ?? Wallet(name: "", type: .cash)
        if cash.modelContext == nil { context.insert(cash) }
        (cash.name, cash.currencyCode, cash.initialBalance) = ("Tiền mặt", vnd, 1_200_000)
        let vcb = Wallet(name: "Vietcombank", type: .bank, currencyCode: vnd, initialBalance: 9_000_000, order: 1)
        let momo = Wallet(name: "MoMo", type: .ewallet, currencyCode: vnd, initialBalance: 600_000, order: 2)
        let visa = Wallet(name: "Visa VPBank", type: .credit, currencyCode: vnd, creditLimit: 30_000_000, order: 3)
        (visa.statementDay, visa.dueDay) = (25, 10)
        let savings = Wallet(name: "Tiết kiệm VCB", type: .savings, currencyCode: vnd, initialBalance: 30_000_000, order: 4)
        let stocks = Wallet(name: "Chứng khoán SSI", type: .investment, currencyCode: vnd, initialBalance: 12_000_000, order: 5)
        [vcb, momo, visa, savings, stocks].forEach(context.insert)

        // Holdings bought before the history starts.
        let gold = Asset(symbol: "SJC", kind: .gold, quantity: 0.3, unitPrice: 152_000_000, currencyCode: vnd)
        gold.costBasis = 39_000_000
        let fpt = Asset(symbol: "FPT", kind: .stock, quantity: 100, unitPrice: 118_000, currencyCode: vnd)
        fpt.costBasis = 11_500_000
        let usd = Asset(symbol: "USD", kind: .fx, quantity: 500, unitPrice: 26_350, currencyCode: vnd)
        usd.costBasis = 12_600_000
        [gold, fpt, usd].forEach(context.insert)

        let today = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .month, value: -3, to: today)!
        let days = cal.dateComponents([.day], from: start, to: today).day!
        let thisMonth = cal.dateInterval(of: .month, for: today)!
        let lastMonth = cal.dateInterval(of: .month, for: thisMonth.start.addingTimeInterval(-1))!
        let twoAgo = cal.dateInterval(of: .month, for: lastMonth.start.addingTimeInterval(-1))!

        // Wallet balances while generating, so cash and MoMo get topped up before they run dry.
        var balance: [ObjectIdentifier: Int] = [ObjectIdentifier(cash): cash.initialBalance, ObjectIdentifier(vcb): vcb.initialBalance,
                                                ObjectIdentifier(momo): momo.initialBalance]
        var made: [Txn] = []
        var cardOwed = 0, statement = 0

        func record(_ t: Txn, _ delta: [(Wallet, Int)]) {
            context.insert(t)
            if t.kind != .income { t.allocate(jars: jars, in: context) } // incomes go through `receive`
            for (w, d) in delta { balance[ObjectIdentifier(w), default: 0] += d }
            made.append(t)
        }
        func transfer(_ amount: Int, _ from: Wallet, _ to: Wallet, _ note: String, _ date: Date) {
            let t = Txn(amount: amount, kind: .transfer, currencyCode: vnd, date: date, note: note, wallet: from)
            t.toWallet = to
            record(t, [(from, -amount), (to, amount)])
        }
        func ensure(_ w: Wallet, _ amount: Int, _ date: Date) {
            guard w === cash || w === momo, balance[ObjectIdentifier(w), default: 0] < amount + 100_000 else { return }
            if w === cash { transfer(2_000_000, vcb, cash, "Rút tiền mặt", date.addingTimeInterval(-900)) }
            else { transfer(1_000_000, vcb, momo, "Nạp MoMo", date.addingTimeInterval(-900)) }
        }
        func spend(_ amount: Int, _ category: String, _ note: String, _ w: Wallet, _ date: Date) {
            guard date <= now else { return }
            ensure(w, amount, date)
            record(Txn(amount: amount, kind: .expense, currencyCode: vnd, date: date, note: note, category: cats[category], wallet: w), [(w, -amount)])
            if w === visa { cardOwed += amount }
        }
        func debt(_ kind: TxKind, _ d: Debt, _ amount: Int, _ w: Wallet, _ date: Date, _ note: String = "") {
            if kind == .lend { ensure(w, amount, date) }
            let t = Txn(amount: amount, kind: kind, currencyCode: vnd, date: date, note: note, wallet: w)
            t.debt = d
            let paysOut = kind == .lend || (kind == .repay && d.direction == .borrowed)
            record(t, [(w, paysOut ? -amount : amount)])
        }
        func person(_ name: String, _ direction: DebtDirection, due: Int?, daysAgo: Int) -> Debt {
            let d = Debt(person: name, direction: direction, currencyCode: vnd, dueDate: due.flatMap { cal.date(byAdding: .day, value: $0, to: today) })
            d.createdAt = cal.date(byAdding: .day, value: -daysAgo, to: today)!
            context.insert(d)
            return d
        }
        /// The books so far.
        func ledger() -> Ledger<PersistentIdentifier> {
            try? context.save() // permanent ids
            return Ledger(txns: (try? context.fetch(FetchDescriptor<Txn>())) ?? [], wallets: (try? context.fetch(FetchDescriptor<Wallet>())) ?? [],
                          jars: jars)
        }

        // Opening balances were in the books before the history starts: split by percent.
        let opening = cash.initialBalance + vcb.initialBalance + momo.initialBalance
        BudgetActions.receive(opening, level: .manual, date: cal.date(bySettingHour: 7, minute: 0, second: 0, of: start)!, in: context)

        // Bills: this month's due date as days from today, paid yet. Earlier months were paid on their day.
        struct Bill { var name: String; var amount: Int; var estimate = false; var category: String; var wallet: Wallet; var offset: Int; var paid: Bool }
        let dom = cal.component(.day, from: today)
        let bills = [
            Bill(name: "Tiền nhà", amount: 5_000_000, category: "category.housing", wallet: vcb, offset: 1 - dom, paid: true),
            Bill(name: "Tiền điện", amount: 750_000, estimate: true, category: "category.housing", wallet: vcb, offset: 3, paid: false), // due soon
            Bill(name: "Internet FPT", amount: 220_000, category: "category.housing", wallet: vcb, offset: 9, paid: false),
            Bill(name: "Netflix", amount: 260_000, category: "category.entertainment", wallet: visa, offset: -2, paid: false), // overdue
            Bill(name: "Cước điện thoại", amount: 150_000, category: "category.housing", wallet: momo, offset: -6, paid: true),
        ]
        func due(_ b: Bill, monthsBack: Int) -> Date {
            cal.date(byAdding: .month, value: -monthsBack, to: cal.date(byAdding: .day, value: b.offset, to: today)!)!
        }

        let tuan = person("Tuấn", .lent, due: 10, daysAgo: 38) // partly repaid
        let lan = person("chị Lan", .borrowed, due: 4, daysAgo: 25) // I owe, due soon
        let hoa = person("Hoa", .lent, due: nil, daysAgo: 4)
        let nam = person("Nam", .lent, due: nil, daysAgo: 60) // repaid in full

        for i in 0...days {
            let day = cal.date(byAdding: .day, value: i, to: start)!
            let back = days - i
            let d = cal.component(.day, from: day), weekday = cal.component(.weekday, from: day)
            let (saturday, sunday) = (weekday == 7, weekday == 1)
            func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: day)! }

            if d == 1, thisMonth.contains(day) { // last month's Play overspend covered from Savings, plus enough to reach payday
                let play = jar("jar.play"), short = -ledger().jarBalance(play.persistentModelID)
                if short > 0 {
                    BudgetActions.moveBetweenJars(short + 1_000_000, from: jar("jar.savings"), to: play, note: "Bù hũ Chơi tháng trước",
                                                  date: at(7, 30), jars: jars, in: context)
                }
            }
            if chance(0.85) { spend(k(25, 45), "category.food", any(["Bánh mì", "Phở", "Xôi gà", "Bún bò", "Hủ tiếu"]), cash, at(7, 10)) }
            if !saturday, !sunday, chance(0.35) { spend(k(30, 75), "category.transport", "Grab đi làm", momo, at(8, 10)) }
            if d == 5, at(9) <= now { // payday, split by percent (what "By percent" on the Budget card does)
                let t = Txn(amount: 25_000_000, kind: .income, currencyCode: vnd, date: at(9), note: "Lương", category: cats["category.salary"], wallet: vcb)
                record(t, [(vcb, t.amount)])
                BudgetActions.receive(income: t, level: .manual, date: t.date, in: context)
            }
            if d == 8, statement > 0, at(9, 15) <= now {
                BudgetActions.payCard(visa, amount: statement, from: vcb, date: at(9, 15), jars: jars, in: context)
                balance[ObjectIdentifier(vcb), default: 0] -= statement
                (cardOwed, statement) = (cardOwed - statement, 0)
            }
            for b in bills {
                for m in (b.paid ? 0 : 1)...3 where cal.isDate(due(b, monthsBack: m), inSameDayAs: day) {
                    spend(b.estimate ? k(680, 860) : b.amount, b.category, b.name, b.wallet, at(9, 30))
                }
            }
            if d == 15, twoAgo.contains(day) { // FPT shares out of the Investing jar
                BudgetActions.setAside(3_000_000, from: vcb, jar: jar("jar.investing"), asset: fpt, quantity: 25, date: at(10), in: context)
                balance[ObjectIdentifier(vcb), default: 0] -= 3_000_000
            }
            if d == 6, lastMonth.contains(day) { // a term deposit out of the Savings jar
                BudgetActions.setAside(4_000_000, from: vcb, jar: jar("jar.savings"), into: savings, date: at(10), in: context)
                balance[ObjectIdentifier(vcb), default: 0] -= 4_000_000
            }
            if chance(0.55) { spend(k(29, 65), "category.food", any(["Cà phê", "Highlands", "Phúc Long", "Trà sữa"]), momo, at(chance(0.5) ? 10 : 15, 20)) }
            if !saturday, !sunday, chance(0.95) {
                spend(k(40, 70), "category.food", any(["Cơm trưa", "Cơm tấm", "Bún chả", "Mì Quảng", "Cơm văn phòng"]), chance(0.5) ? cash : momo, at(12, 5))
            }
            if sunday { spend(k(250, 480), "category.food", any(["Đi chợ", "Bách hoá Xanh", "Co.op Mart"]), cash, at(9, 40)) }
            if d == 12 { spend(1_500_000, "category.education", "Học phí IELTS", vcb, at(19)) }
            if d == 18, chance(0.6) { spend(k(90, 250), "category.education", "Mua sách", momo, at(20)) }
            if d == 14 { spend(500_000, "category.charity", "Mừng cưới", cash, at(18)) }
            if d == 20 { spend(100_000, "category.charity", "Quyên góp", momo, at(21)) }
            if i % 6 == 2 { spend(k(70, 95), "category.transport", "Đổ xăng", cash, at(18, 30)) }
            if i % 17 == 5 { spend(k(60, 220), "category.health", "Nhà thuốc", cash, at(17, 45)) }
            if saturday, chance(0.6) { spend(k(200, 450), "category.entertainment", any(["Lẩu với bạn", "Nướng cuối tuần", "Ăn tối với bạn"]), visa, at(19)) }
            if saturday, chance(0.3) { spend(k(150, 240), "category.entertainment", "Xem phim CGV", visa, at(21)) }
            if d == 23 { spend(k(150, 700), "category.shopping", any(["Shopee", "Lazada", "Uniqlo"]), visa, at(21, 30)) }
            if cal.isDate(day, inSameDayAs: lastMonth.end.addingTimeInterval(-1)) { // the Play jar ends last month slightly over budget
                let m = ledger().jarMonth(jar("jar.play").persistentModelID, in: lastMonth)
                spend((max(m.budget - m.spent, 0) + k(250, 450)) / 10_000 * 10_000, "category.shopping", "Tai nghe Sony", visa, at(21, 45))
            }
            if d == 25 { statement = cardOwed }

            switch back {
            case 60: debt(.lend, nam, 300_000, momo, at(20), "Nam mượn")
            case 46: debt(.repay, nam, 300_000, momo, at(20))
            case 38: debt(.lend, tuan, 2_000_000, vcb, at(19), "Tuấn mượn sửa xe")
            case 25: debt(.borrow, lan, 3_000_000, vcb, at(11), "Mượn chị Lan")
            case 15: debt(.repay, tuan, 500_000, momo, at(20, 30))
            case 4: debt(.lend, hoa, 500_000, cash, at(18, 15), "Hoa mượn")
            case 2: // side income waits in Unallocated: help level Suggest, so the Budget card offers a plan
                let t = Txn(amount: 3_000_000, kind: .income, currencyCode: vnd, date: at(20), note: "Thiết kế logo",
                            category: cats["category.otherIncome"], wallet: momo)
                record(t, [(momo, t.amount)])
                BudgetActions.receive(income: t, level: .suggest, date: t.date, in: context)
            default: break
            }
        }

        // Bills and salary as they stand today.
        for b in bills {
            let r = Recurring(name: b.name, amount: b.amount, currencyCode: vnd, nextDue: due(b, monthsBack: b.paid ? -1 : 0))
            context.insert(r)
            (r.isEstimate, r.category, r.wallet) = (b.estimate, cats[b.category], b.wallet)
            r.dueDay = cal.component(.day, from: due(b, monthsBack: 0))
            r.lastPaid = made.filter { $0.note == b.name }.map(\.date).max()
        }
        let paid = made.filter { $0.kind == .income && $0.category?.key == "category.salary" }.map(\.date).max()
        let salary = Recurring(name: "Lương", amount: 25_000_000, currencyCode: vnd,
                               nextDue: BudgetActions.nextDate(day: 5, from: cal.date(byAdding: .day, value: 1, to: paid ?? today)!, calendar: cal))
        context.insert(salary)
        (salary.category, salary.wallet, salary.dueDay, salary.lastPaid) = (cats["category.salary"], vcb, 5, paid)

        fpt.unitPrice = 124_500 // today's price, above what was paid
        fpt.updatedAt = now

        // Chats on past days: Moonee's confirmations linked to their txns.
        for (n, back) in [9, 4, 1].enumerated() {
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            let logged = made.filter { cal.isDate($0.date, inSameDayAs: day) }.sorted { $0.date < $1.date }
            let picked = Array(logged.filter { $0.kind == .expense }.prefix(2)) + logged.filter { $0.kind == .lend }
            guard let first = picked.first else { continue }
            let thread = ChatThread(day: day, createdAt: first.date)
            context.insert(thread)
            for (j, t) in picked.enumerated() {
                let said = t.kind == .lend ? "cho \(t.debt?.person ?? "") mượn \(t.amount / 1000)k" : "\(t.note.lowercased()) \(t.amount / 1000)k"
                (t.source, t.rawInput) = (.text, said)
                let user = ChatMessage(fromUser: true, text: said, date: t.date)
                let reply = ChatMessage(fromUser: false, text: ChatLines.saved([t], calendar: cal, variant: n + j), date: t.date.addingTimeInterval(2))
                [user, reply].forEach(context.insert)
                ChatThreads.add(user, to: thread)
                ChatThreads.add(reply, to: thread)
                t.chatMessage = reply
            }
        }
    }
}

/// SplitMix64: the same sample data on every run.
struct SeededRandom: RandomNumberGenerator {
    var seed: UInt64

    mutating func next() -> UInt64 {
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
