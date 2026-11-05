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

        func add(_ amount: Int, _ kind: TxKind, _ key: String?, _ note: String, _ date: Date, _ wallet: Wallet) {
            let t = Txn(amount: amount, kind: kind, date: date, note: note, category: key.flatMap { cat[$0] }, wallet: wallet)
            context.insert(t)
            t.allocate(jars: jars, in: context)
        }
        add(18_000_000, .income, "category.salary", "", lastMonth.addingTimeInterval(86_400 * 4), bank)
        add(18_000_000, .income, "category.salary", "", monthStart, bank)
        add(4_500_000, .expense, "category.housing", "Tiền nhà", lastMonth.addingTimeInterval(86_400 * 5), bank)
        add(4_500_000, .expense, "category.housing", "Tiền nhà", day(3), bank)
        add(1_200_000, .expense, "category.shopping", "Giày chạy bộ", day(6), card)
        add(850_000, .expense, "category.food", "Đi chợ", day(4), cash)
        add(320_000, .expense, "category.transport", "Đổ xăng", day(2), cash)
        add(112_000, .expense, "category.food", "Cà phê", day(1, 9), cash)
        add(120_000, .expense, "category.education", "Mua sách", day(1, 19), bank)
        add(65_000, .expense, "category.food", "Ăn trưa", day(0, 12), cash)

        let internet = Recurring(name: "Internet", amount: 199_000, nextDue: day(-2))
        internet.category = cat["category.housing"]
        let visa = Recurring(name: "Visa", amount: 2_500_000, nextDue: day(-4))
        [internet, visa, Recurring(name: "Netflix", amount: 260_000, nextDue: day(-15))].forEach(context.insert)
        context.insert(Asset(symbol: "SJC", kind: .gold, quantity: 2, unitPrice: 85_000_000))
        try? context.save()
    }
}
#endif
