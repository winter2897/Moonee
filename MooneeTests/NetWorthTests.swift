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

    @Test func partsSplitNetWorthByType() {
        let l = L(entries: [
            .init(kind: .expense, amount: 2_000_000, date: day(2026, 11), wallet: "card"),  // card debt
            .init(kind: .lend, amount: 3_000_000, date: day(2026, 11), wallet: "bank", debt: "nam"),
            .init(kind: .repay, amount: 500_000, date: day(2026, 11), wallet: "bank", debt: "nam"),
            .init(kind: .borrow, amount: 5_000_000, date: day(2026, 11), wallet: "bank", debt: "mom"),
            .init(kind: .repay, amount: 1_000_000, date: day(2026, 11), wallet: "bank", debt: "mom"),
        ], walletOpening: ["bank": 10_000_000], debtDirections: ["nam": .lent, "mom": .borrowed])
        let assets: [(kind: AssetKind, value: Int)] = [(.gold, 80_000_000), (.stock, 5_000_000), (.gold, 1_000_000), (.other, 30_000_000)]

        let p = l.parts(assets: assets)
        // bank: 10M − 3M lent + 0.5M back + 5M borrowed − 1M repaid = 11.5M
        #expect(p == NetWorthParts(cash: 11_500_000, assets: [.gold: 81_000_000, .stock: 5_000_000, .other: 30_000_000],
                                   lent: 2_500_000, cardDebt: 2_000_000, borrowed: 4_000_000))
        #expect(p.total == l.netWorth(assets: assets.map(\.value).reduce(0, +)))
        #expect(p.owned == p.total + p.debts)
    }

    @Test func assetsInAnotherCurrencyStayOutOfNetWorth() {
        let assets = [Asset(symbol: "SJC", kind: .gold, quantity: 2, unitPrice: 82_600_000, currencyCode: "VND"),
                      Asset(symbol: "AAPL", kind: .stock, quantity: 1.5, unitPrice: 19_842, currencyCode: "USD")]
        let counted = Asset.counted(assets, currency: "VND")
        #expect(counted.count == 1)
        #expect(counted.first?.value == 165_200_000)
        #expect(assets[1].value == 29_763) // 1.5 × $198.42, rounded to cents
    }

    @Test func historyFillsMonthsWithoutSnapshotFromTheEstimate() {
        let now = day(2026, 11, 5)
        let snaps = [(month(2026, 7), 70), (month(2026, 9), 90), (month(2026, 11), 999)]
        var asked: [Date] = []
        let points = NetWorthHistory.points(snaps.map { (month: $0.0, total: $0.1) }, current: 4, since: day(2026, 3),
                                            estimate: { asked.append($0); return -1 }, now: now, calendar: cal)
        // 6 months: Jun–Oct, then Nov at the live total (its stored snapshot is replaced).
        #expect(points.map(\.month) == [6, 7, 8, 9, 10, 11].map { month(2026, $0) })
        #expect(points.map(\.total) == [-1, 70, -1, 90, -1, 4])
        #expect(asked == [month(2026, 7), month(2026, 9), month(2026, 11)]) // estimated at each month's end
    }

    @Test func historyStartsOneMonthBeforeTheFirstData() {
        let now = day(2026, 11, 5)
        let p = { (since: Date?, snaps: [(Date, Int)]) in
            NetWorthHistory.points(snaps.map { (month: $0.0, total: $0.1) }, current: 4, since: since,
                                   estimate: { _ in 0 }, now: now, calendar: self.cal).map(\.month)
        }
        // A new user still gets a trend: last month (before Moonee) → this month.
        #expect(p(nil, []) == [month(2026, 10), month(2026, 11)])
        #expect(p(day(2026, 11, 2), []) == [month(2026, 10), month(2026, 11)])
        #expect(p(day(2026, 10, 20), []) == [9, 10, 11].map { month(2026, $0) })
        #expect(p(nil, [(month(2026, 9), 1)]) == [8, 9, 10, 11].map { month(2026, $0) })
        #expect(NetWorthHistory.points([], current: 4, since: day(2025, 1), estimate: { _ in 0 }, now: now, months: 3,
                                       calendar: cal).map(\.month) == [9, 10, 11].map { month(2026, $0) }) // 3T range
    }

    @Test func historyRebuildsMonthEndsFromTheLedger() {
        // Salary 10tr on 20 Oct, spent 3tr on 3 Nov, lent 1tr on 4 Nov (still owned), gold worth 5tr today.
        let entries: [L.Entry] = [
            .init(kind: .income, amount: 10_000_000, date: day(2026, 10, 20), wallet: "bank"),
            .init(kind: .expense, amount: 3_000_000, date: day(2026, 11, 3), wallet: "bank"),
            .init(kind: .lend, amount: 1_000_000, date: day(2026, 11, 4), wallet: "bank", debt: "nam"),
        ]
        let gold = 5_000_000
        let now = day(2026, 11, 5)
        let points = NetWorthHistory.points([], current: L(entries: entries, debtDirections: ["nam": .lent]).netWorth(assets: gold), since: day(2026, 10, 20),
                                            estimate: { end in L(entries: entries.filter { $0.date < end }, debtDirections: ["nam": .lent]).netWorth(assets: gold) },
                                            now: now, calendar: cal)
        #expect(points.map(\.total) == [5_000_000, 15_000_000, 12_000_000]) // Sep: gold only · Oct end · Nov now
        let change = NetWorthHistory.change(points)
        #expect(change?.amount == -3_000_000) // vs October, not vs September
        #expect(change?.percent == -0.2)
    }

    @Test func changeIsVsThePreviousMonth() throws {
        let pts = { (totals: [Int]) in totals.enumerated().map { NetWorthHistory.Point(month: self.month(2026, 5 + $0.offset), total: $0.element) } }
        let up = try #require(NetWorthHistory.change(pts([999, 200, 250])))
        #expect(up.amount == 50)
        #expect(up.percent == 0.25)
        #expect(NetWorthHistory.change(pts([-200, -100]))?.percent == 0.5) // less negative = up
        #expect(NetWorthHistory.change(pts([0, 100]))?.percent == nil)
        #expect(NetWorthHistory.change(pts([250])) == nil)
    }

    @Test func selectionPicksTheMonthTouched() {
        let points = [5, 6, 7].map { NetWorthHistory.Point(month: month(2026, $0), total: $0) }
        #expect(NetWorthHistory.nearest(points, to: day(2026, 6, 1))?.total == 6)
        #expect(NetWorthHistory.nearest(points, to: day(2026, 6, 28))?.total == 6) // the whole June bar is June
        #expect(NetWorthHistory.nearest(points, to: day(2027, 1))?.total == 7)
        #expect(NetWorthHistory.nearest(points, to: day(2026, 1))?.total == 5)
        #expect(NetWorthHistory.nearest([], to: day(2026, 6)) == nil)
    }

    @Test func recordKeepsOneSnapshotPerMonth() throws {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: .init(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
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
