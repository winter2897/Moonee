import Foundation
import Testing
@testable import Moonee

struct SpendingCalendarTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        c.firstWeekday = 2 // Monday
        return c
    }()

    func day(_ m: Int, _ d: Int, _ h: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))! }

    @Test func totalsPerDayExpensesOnly() {
        let txns = [
            Txn(amount: 50_000, kind: .expense, date: day(11, 3, 8)),
            Txn(amount: 30_000, kind: .expense, date: day(11, 3, 23)),   // same day, late
            Txn(amount: 9_000_000, kind: .income, date: day(11, 3)),     // income ignored
            Txn(amount: 70_000, kind: .expense, date: day(10, 31, 23)),  // last month
            Txn(amount: 10_000, kind: .expense, date: day(11, 30, 22)),
        ]
        let c = SpendingCalendar(txns: txns, month: day(11, 15), calendar: cal)
        #expect(c.days.count == 30)
        #expect(c.days[2].total == 80_000)
        #expect(c.days[29].total == 10_000)
        #expect(c.total == 90_000)
        #expect(c.days[0].level == 0)
        #expect(c.days[2].level == 4)
        #expect(c.days[29].level == 1)
    }

    @Test func outlierDoesNotWashOut() {
        let levels = SpendingCalendar.levels([0, 100, 200, 300, 400, 50_000_000, 200])
        #expect(levels[0] == 0)
        #expect(levels[100] == 1)
        #expect(levels[300] == 2)
        #expect(levels[400] == 3)  // a linear scale would make it as light as 100
        #expect(levels[50_000_000] == 4)
        #expect(SpendingCalendar.levels([45_000, 45_000])[45_000] == 4)
    }

    @Test func weeksStartOnFirstWeekday() {
        // 1 Nov 2026 is a Sunday: 6 blanks Monday-first, none Sunday-first.
        #expect(SpendingCalendar(txns: [], month: day(11, 1), calendar: cal).leadingBlanks == 6)
        var sunday = cal
        sunday.firstWeekday = 1
        #expect(SpendingCalendar(txns: [], month: day(11, 1), calendar: sunday).leadingBlanks == 0)
        #expect(SpendingCalendar(txns: [], month: day(2, 10), calendar: cal).days.count == 28)
    }
}
