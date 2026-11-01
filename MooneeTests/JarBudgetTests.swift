import Foundation
import Testing
@testable import Moonee

struct JarBudgetTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func day(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }

    @Test func budgetsSpentAndOver() {
        let needs = Jar(name: "Thiết yếu", icon: "", colorHex: 0, percent: 55, order: 0)
        let play = Jar(name: "Hưởng thụ", icon: "", colorHex: 0, percent: 45, order: 1)
        let food = Category(name: "Ăn uống", icon: "", colorHex: 0, jar: needs)
        let fun = Category(name: "Giải trí", icon: "", colorHex: 0, jar: play)
        let other = Category(name: "Khác", icon: "", colorHex: 0)
        let txns = [
            Txn(amount: 10_000_000, kind: .income, date: day(11, 1)),
            Txn(amount: 1_000_000, kind: .expense, date: day(11, 3), category: food),
            Txn(amount: 5_000_000, kind: .expense, date: day(11, 4), category: fun),
            Txn(amount: 300_000, kind: .expense, date: day(11, 5), category: other),  // category without jar
            Txn(amount: 200_000, kind: .expense, date: day(11, 6)),                   // no category
            Txn(amount: 9_999_999, kind: .expense, date: day(10, 31), category: food), // previous month
        ]
        let b = JarBudget(txns: txns, jars: [play, needs], anchor: day(11, 15), calendar: cal)
        #expect(b.income == 10_000_000)
        #expect(b.spent == 6_500_000)
        #expect(b.unassigned == 500_000)
        #expect(b.rows.map(\.jar.name) == ["Thiết yếu", "Hưởng thụ"]) // sorted by order
        #expect(b.rows[0].budget == 5_500_000)
        #expect(b.rows[0].left == 4_500_000)
        #expect(!b.rows[0].isOver)
        #expect(b.rows[1].budget == 4_500_000)
        #expect(b.rows[1].isOver)
        #expect(b.rows[1].left == -500_000)
        #expect(b.rows[1].progress == 1)
    }

    @Test func noIncomeMeansZeroBudgets() {
        let jar = Jar(name: "A", icon: "", colorHex: 0, percent: 100, order: 0)
        let cat = Category(name: "C", icon: "", colorHex: 0, jar: jar)
        let b = JarBudget(txns: [Txn(amount: 50_000, kind: .expense, date: day(11, 2), category: cat)], jars: [jar], anchor: day(11, 2), calendar: cal)
        #expect(b.income == 0)
        #expect(b.rows[0].budget == 0)
        #expect(b.rows[0].isOver)
        #expect(b.rows[0].progress == 1)

        let empty = JarBudget(txns: [], jars: [jar], anchor: day(11, 2), calendar: cal)
        #expect(empty.rows[0].progress == 0)
        #expect(!empty.rows[0].isOver)
    }

    @Test func percentsNotSummingTo100AreNormalized() {
        let a = Jar(name: "A", icon: "", colorHex: 0, percent: 30, order: 0)
        let b = Jar(name: "B", icon: "", colorHex: 0, percent: 10, order: 1)
        let income = [Txn(amount: 4_000_000, kind: .income, date: day(11, 1))]
        let budget = JarBudget(txns: income, jars: [a, b], anchor: day(11, 1), calendar: cal)
        #expect(budget.percentTotal == 40)
        #expect(budget.rows.map(\.budget) == [3_000_000, 1_000_000])

        let zero = Jar(name: "Z", icon: "", colorHex: 0, percent: 0, order: 0)
        #expect(JarBudget(txns: income, jars: [zero], anchor: day(11, 1), calendar: cal).rows[0].budget == 0)
    }
}
