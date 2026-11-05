import Foundation
import Testing
@testable import Moonee

struct SpendingSummaryTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func day(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }

    @Test func monthTotalsAndChange() {
        let txns = [
            Txn(amount: 80_000, kind: .expense, date: day(11, 1)),
            Txn(amount: 20_000, kind: .expense, date: day(11, 30)),
            Txn(amount: 5_000_000, kind: .income, date: day(11, 5)),   // income ignored
            Txn(amount: 200_000, kind: .expense, date: day(10, 15)),   // previous month
            Txn(amount: 999, kind: .expense, date: day(12, 1)),        // next month ignored
        ]
        let s = SpendingSummary(txns: txns, period: .month, anchor: day(11, 10), calendar: cal)
        #expect(s.total == 100_000)
        #expect(s.previousTotal == 200_000)
        #expect(s.change == -50)
        #expect(s.rows.count == 1) // all uncategorized
    }

    @Test func noPreviousMeansNoChange() {
        let s = SpendingSummary(txns: [Txn(amount: 1, kind: .expense, date: day(11, 2))], period: .year, anchor: day(11, 2), calendar: cal)
        #expect(s.change == nil)
    }

    @Test func vndFormatting() {
        #expect(250_000.vnd == "250.000 đ")
    }
}
