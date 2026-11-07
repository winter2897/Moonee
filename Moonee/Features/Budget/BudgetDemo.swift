#if DEBUG
import Foundation
import SwiftData

/// Debug only: launch with `-budgetDemo` on an empty store to get the Budget mockup's data (screenshots, review).
/// `-ownerDemo <bank balance>`: the owner's build-3 phone (cash −113k after lunch, salary 40tr on the 10th, bills 5.14tr).
enum BudgetDemo {
    @MainActor static func seedIfRequested(_ context: ModelContext) {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-ownerDemo"), (try? context.fetchCount(FetchDescriptor<Txn>())) == 0 {
            owner(bank: args.indices.contains(i + 1) ? Int(args[i + 1]) ?? 0 : 0, in: context)
            return
        }
        guard args.contains("-budgetDemo"),
              (try? context.fetchCount(FetchDescriptor<Txn>())) == 0 else { return }
        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let cats = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let cat = { (key: String) in cats.first { $0.key == key } }
        let cal = Calendar.current
        let month = cal.dateInterval(of: .month, for: .now)!.start
        let day = { (d: Int) in cal.date(byAdding: .day, value: d - 1, to: month)! }
        let cash = (try? context.fetch(FetchDescriptor<Wallet>()))?.first ?? Wallet(name: "Cash", type: .cash)
        cash.initialBalance = 1_500_000
        let bank = Wallet(name: "Vietcombank", type: .bank, initialBalance: 8_000_000, order: 1)
        let momo = Wallet(name: "MoMo", type: .ewallet, initialBalance: 2_400_000, order: 2)
        let card = Wallet(name: "Visa Platinum", type: .credit, creditLimit: 30_000_000, order: 3)
        card.statementDay = 20
        card.dueDay = 5
        [bank, momo, card].forEach(context.insert)

        func add(_ amount: Int, _ kind: TxKind, _ d: Int, _ category: String?, _ wallet: Wallet, _ note: String = "") {
            let t = Txn(amount: amount, kind: kind, date: day(d), note: note, category: category.flatMap(cat), wallet: wallet)
            context.insert(t)
            t.allocate(jars: jars, in: context)
        }
        add(20_000_000, .income, 1, "category.salary", bank)
        add(6_500_000, .expense, 2, "category.housing", bank, "Tiền nhà")
        add(1_600_000, .expense, 3, "category.education", momo, "Khoá học")
        add(2_450_000, .expense, 4, "category.shopping", card, "Giày")
        add(180_000, .expense, 5, "category.food", cash, "Phở + cafe")
        // Category limits (P1-1): food at 90%, housing over, shopping's limit more than the Fun jar has.
        for (key, limit) in [("category.food", 200_000), ("category.housing", 6_000_000), ("category.shopping", 3_000_000)] { cat(key)?.monthlyLimit = limit }
        if jars.count > 2 { BudgetActions.moveBetweenJars(600_000, from: jars[2], to: jars[1], jars: jars, in: context) }

        let rent = Recurring(name: "Internet", amount: 220_000, nextDue: cal.date(byAdding: .day, value: 3, to: .now)!)
        let power = Recurring(name: "Tiền điện", amount: 650_000, nextDue: .now)
        power.isEstimate = true
        let netflix = Recurring(name: "Netflix", amount: 260_000, nextDue: cal.date(byAdding: .day, value: -2, to: .now)!)
        netflix.autoPost = true // P1-4: Moonee records it on launch (Budget card + chat, with Undo)
        let house = Recurring(name: "Tiền nhà", amount: 5_000_000, nextDue: cal.date(byAdding: .month, value: 1, to: day(5))!)
        house.lastPaid = day(2)
        for (r, c) in [(rent, "category.housing"), (power, "category.housing"), (netflix, "category.entertainment"), (house, "category.housing")] {
            context.insert(r)
            r.category = cat(c)
            r.wallet = bank
        }

        // Debt book: Nam owes 300k (due in 5 days), Hùng 500k with no date, I owe Lan 2tr; Minh paid back in full.
        func debt(_ person: String, _ direction: DebtDirection, _ amount: Int, due: Int?, repaid: Int = 0) {
            let d = Debt(person: person, direction: direction, dueDate: due.flatMap { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: .now)) })
            context.insert(d)
            let t = Txn(amount: amount, kind: direction == .lent ? .lend : .borrow, date: day(3), wallet: bank)
            context.insert(t)
            t.debt = d
            if repaid > 0 {
                let r = Txn(amount: repaid, kind: .repay, date: day(5), wallet: cash)
                context.insert(r)
                r.debt = d
            }
        }
        debt("Nam", .lent, 500_000, due: 5, repaid: 200_000)
        debt("Hùng", .lent, 500_000, due: nil)
        debt("Lan", .borrowed, 2_000_000, due: 12)
        debt("Minh", .lent, 150_000, due: nil, repaid: 150_000)
    }

    @MainActor private static func owner(bank: Int, in context: ModelContext) {
        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let food = ((try? context.fetch(FetchDescriptor<Category>())) ?? []).first { $0.key == "category.food" }
        let housing = ((try? context.fetch(FetchDescriptor<Category>())) ?? []).first { $0.key == "category.housing" }
        OnboardingBook.saveSalary(40_000_000, payday: 10, regular: true, in: context)
        let wallets = OnboardingBook.saveWallets([.init(type: .cash, name: "", amount: 0), .init(type: .bank, name: "Ngân hàng", amount: bank)], in: context)
        let lunch = Txn(amount: 113_000, kind: .expense, note: "Ăn trưa", category: food, wallet: wallets.first)
        context.insert(lunch)
        lunch.allocate(jars: jars, in: context)
        let cal = Calendar.current
        for (name, amount, day) in [("Tiền nhà", 4_000_000, 15), ("Điện nước", 1_140_000, 20)] {
            let bill = Recurring(name: name, amount: amount, nextDue: BudgetActions.nextDate(day: day, calendar: cal))
            context.insert(bill)
            bill.category = housing
        }
    }
}
#endif
