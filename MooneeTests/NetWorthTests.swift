import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor
struct NetWorthTests {
    typealias L = Ledger<String>
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func day(_ y: Int, _ m: Int, _ d: Int = 15) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
    func month(_ y: Int, _ m: Int) -> Date { cal.dateInterval(of: .month, for: day(y, m))!.start }

    @Test func breakdownSplitsNetWorthIntoFourSlices() {
        let l = L(entries: [
            .init(kind: .expense, amount: 2_000_000, date: day(2026, 11), wallet: "card"),  // card debt
            .init(kind: .lend, amount: 3_000_000, date: day(2026, 11), wallet: "bank", debt: "nam"),
            .init(kind: .repay, amount: 500_000, date: day(2026, 11), wallet: "bank", debt: "nam"),
            .init(kind: .borrow, amount: 5_000_000, date: day(2026, 11), wallet: "bank", debt: "mom"),
            .init(kind: .repay, amount: 1_000_000, date: day(2026, 11), wallet: "bank", debt: "mom"),
        ], walletOpening: ["bank": 10_000_000], debtDirections: ["nam": .lent, "mom": .borrowed])
        let assets: [(kind: AssetKind, value: Int)] = [(.gold, 80_000_000), (.stock, 5_000_000), (.fx, 25_000_000), (.other, 30_000_000)]

        let b = l.breakdown(assets: assets)
        // bank: 10M − 3M lent + 0.5M back + 5M borrowed − 1M repaid = 11.5M
        #expect(b == NetWorthBreakdown(cash: 11_500_000 + 25_000_000, investments: 85_000_000,
                                       other: 30_000_000 + 2_500_000, debts: 2_000_000 + 4_000_000))
        #expect(b.total == l.netWorth(assets: assets.map(\.value).reduce(0, +)))
        #expect(b.gross == b.total + b.debts)
    }

    @Test func assetsInAnotherCurrencyStayOutOfNetWorth() {
        let assets = [Asset(symbol: "SJC", kind: .gold, quantity: 2, unitPrice: 82_600_000, currencyCode: "VND"),
                      Asset(symbol: "AAPL", kind: .stock, quantity: 1.5, unitPrice: 19_842, currencyCode: "USD")]
        let counted = Asset.counted(assets, currency: "VND")
        #expect(counted.count == 1)
        #expect(counted.first?.value == 165_200_000)
        #expect(assets[1].value == 29_763) // 1.5 × $198.42, rounded to cents
    }

    @Test func historyKeepsTwelveMonthsAndUsesTheLiveTotalForNow() {
        let now = day(2026, 11, 5)
        let snaps = [(month(2025, 10), 1), (month(2025, 12), 2), (month(2026, 10), 3), (month(2026, 11), 999)]
        let points = NetWorthHistory.points(snaps.map { (month: $0.0, total: $0.1) }, current: 4, now: now, calendar: cal)
        #expect(points.map(\.total) == [2, 3, 4]) // Oct 2025 is 13 months back; Nov's stored value is replaced
        #expect(points.map(\.month) == [month(2025, 12), month(2026, 10), month(2026, 11)])
    }

    @Test func changeIsAgainstLastMonthOnly() throws {
        let now = day(2026, 11, 5)
        let p = { (snaps: [(Date, Int)], current: Int) in
            NetWorthHistory.points(snaps.map { (month: $0.0, total: $0.1) }, current: current, now: now, calendar: self.cal)
        }
        let up = try #require(NetWorthHistory.change(p([(month(2026, 10), 200)], 250), now: now, calendar: cal))
        #expect(up.amount == 50)
        #expect(up.percent == 0.25)
        let fromNegative = try #require(NetWorthHistory.change(p([(month(2026, 10), -200)], -100), now: now, calendar: cal))
        #expect(fromNegative.percent == 0.5) // less negative = up
        #expect(NetWorthHistory.change(p([(month(2026, 10), 0)], 100), now: now, calendar: cal)?.percent == nil)
        #expect(NetWorthHistory.change(p([(month(2026, 9), 200)], 250), now: now, calendar: cal) == nil) // gap
        #expect(NetWorthHistory.change(p([], 250), now: now, calendar: cal) == nil)
    }

    @Test func recordKeepsOneSnapshotPerMonth() throws {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: .init(isStoredInMemoryOnly: true)))
        func snaps() throws -> [NetWorthSnapshot] { try context.fetch(FetchDescriptor<NetWorthSnapshot>(sortBy: [SortDescriptor(\.month)])) }

        NetWorthSnapshot.record(100, currency: "VND", now: day(2026, 10, 3), calendar: cal, in: context)
        NetWorthSnapshot.record(150, currency: "VND", now: day(2026, 10, 28), calendar: cal, in: context)
        #expect(try snaps().map(\.total) == [150])
        #expect(try snaps().first?.month == month(2026, 10))

        NetWorthSnapshot.record(170, currency: "VND", now: day(2026, 11, 1), calendar: cal, in: context)
        NetWorthSnapshot.record(9, currency: "USD", now: day(2026, 11, 1), calendar: cal, in: context)
        #expect(try snaps().filter { $0.currencyCode == "VND" }.map(\.total) == [150, 170])

        // iCloud sync can bring a second copy of a month: the next record merges them.
        context.insert(NetWorthSnapshot(month: month(2026, 11), total: 1, currencyCode: "VND"))
        NetWorthSnapshot.record(180, currency: "VND", now: day(2026, 11, 2), calendar: cal, in: context)
        #expect(try snaps().filter { $0.currencyCode == "VND" }.map(\.total) == [150, 180])
    }
}
