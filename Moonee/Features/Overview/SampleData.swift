#if DEBUG
import SwiftData
import SwiftUI

/// Debug-only demo data for screenshots: launch with `-overviewSample YES` (plus `-money.currency VND` to match the mockups).
/// Inserts once, only into an empty ledger.
enum SampleData {
    @MainActor static func insertIfRequested(_ context: ModelContext) {
        guard UserDefaults.standard.bool(forKey: "overviewSample"), (try? context.fetchCount(FetchDescriptor<Txn>())) == 0,
              let jars = try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)])), !jars.isEmpty,
              let categories = try? context.fetch(FetchDescriptor<Category>()) else { return }
        let cat = Dictionary(categories.compactMap { c in c.key.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        let cash = (try? context.fetch(FetchDescriptor<Wallet>()))?.first ?? Wallet(name: "Cash", type: .cash)
        cash.initialBalance = 1_500_000
        let bank = Wallet(name: String(localized: "Bank account"), type: .bank, initialBalance: 40_000_000, order: 1)
        let card = Wallet(name: "Visa", type: .credit, creditLimit: 30_000_000, order: 2)
        [bank, card].forEach(context.insert)

        let cal = Calendar.current
        func day(_ back: Int, _ hour: Int = 12) -> Date {
            cal.date(bySettingHour: hour, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -back, to: .now)!)!
        }
        let monthStart = cal.dateInterval(of: .month, for: .now)!.start
        let lastMonth = cal.date(byAdding: .month, value: -1, to: monthStart)!

        @discardableResult
        func add(_ amount: Int, _ kind: TxKind, _ key: String?, _ note: String, _ date: Date, _ wallet: Wallet) -> Txn {
            let t = Txn(amount: amount, kind: kind, date: date, note: note, category: key.flatMap { cat[$0] }, wallet: wallet)
            context.insert(t)
            t.allocate(jars: jars, in: context)
            return t
        }
        add(18_000_000, .income, "category.salary", "", cal.date(byAdding: .month, value: -1, to: lastMonth)!.addingTimeInterval(86_400 * 4), bank)
        add(18_000_000, .income, "category.salary", "", lastMonth.addingTimeInterval(86_400 * 4), bank)
        // Moves that aren't income or spending: the ledger marks them "not counted".
        add(2_000_000, .transfer, nil, "Rút tiền mặt", day(5), bank).toWallet = cash
        add(1_450_000, .transfer, nil, "Trả thẻ Visa", day(8), bank).toWallet = card
        let move = add(300_000, .jarTransfer, nil, "", day(7), cash)
        (move.wallet, move.jar, move.toJar) = (nil, jars.first, jars.last)
        add(18_000_000, .income, "category.salary", "", monthStart, bank)
        add(4_500_000, .expense, "category.housing", "Tiền nhà", lastMonth.addingTimeInterval(86_400 * 5), bank)
        add(4_500_000, .expense, "category.housing", "Tiền nhà", day(3), bank)
        add(1_200_000, .expense, "category.shopping", "Giày chạy bộ", day(6), card)
        add(850_000, .expense, "category.food", "Đi chợ", day(4), cash)
        add(320_000, .expense, "category.transport", "Đổ xăng", day(2), cash)
        // A stand-in receipt photo, so the spending calendar's day sheet shows a thumbnail.
        add(112_000, .expense, "category.food", "Cà phê", day(1, 9), cash).attachment =
            UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160)).pngData { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
                UIImage(systemName: "receipt")?.withTintColor(.darkGray).draw(in: CGRect(x: 20, y: 30, width: 80, height: 100))
            }
        add(120_000, .expense, "category.education", "Mua sách", day(1, 19), bank)
        add(65_000, .expense, "category.food", "Ăn trưa", day(0, 12), cash)
        // Daily meals and rides over the last ~10 weeks, so the period charts have a shape to compare.
        let meals = [45_000, 55_000, 38_000, 60_000, 42_000, 70_000, 50_000]
        for back in 2...75 {
            add(meals[back % meals.count], .expense, "category.food", back % 3 == 0 ? "Phở" : "Cơm trưa", day(back, 12), cash)
            if back % 4 == 0 { add(35_000 + back * 500, .expense, "category.transport", "Grab", day(back, 8), cash) }
            if back % 9 == 0 { add(250_000, .expense, "category.entertainment", "Xem phim", day(back, 20), card) }
            if back % 11 == 0 { add(180_000, .expense, "category.health", "Nhà thuốc", day(back, 17), cash) }
        }

        let internet = Recurring(name: "Internet", amount: 199_000, nextDue: day(-2))
        internet.category = cat["category.housing"]
        let visa = Recurring(name: "Visa", amount: 2_500_000, nextDue: day(-4))
        let salary = Recurring(name: String(localized: "category.salary"), amount: 18_000_000, nextDue: cal.date(byAdding: .month, value: 1, to: monthStart)!)
        salary.category = cat["category.salary"]
        [internet, visa, salary, Recurring(name: "Netflix", amount: 260_000, nextDue: day(-15))].forEach(context.insert)
        context.insert(Asset(symbol: "SJC", kind: .gold, quantity: 2, unitPrice: 85_000_000))
        try? context.save()
    }
}
#endif
