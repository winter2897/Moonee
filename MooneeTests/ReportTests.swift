import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor struct ReportTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func at(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }

    /// Two jars (needs 80%, play 20%), food → needs, fun → play. Sep: 1tr food. Oct: 10tr salary, food 2tr + 500k, fun 3tr, one with no category.
    func book() throws -> (ModelContext, [Txn], [Wallet], [Jar]) {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let needs = Jar(key: "jar.essentials", icon: "house", colorHex: 0, percent: 80, order: 0)
        let play = Jar(key: "jar.play", icon: "sparkles", colorHex: 0, percent: 20, order: 1)
        let food = Category(key: "category.food", icon: "fork.knife", colorHex: 0, jar: needs)
        let fun = Category(key: "category.entertainment", icon: "gamecontroller", colorHex: 0, jar: play)
        let cash = Wallet(name: "Cash", type: .cash)
        [needs, play].forEach(context.insert)
        [food, fun].forEach(context.insert)
        context.insert(cash)
        let jars = [needs, play]
        func add(_ amount: Int, _ kind: TxKind, _ date: Date, _ c: Moonee.Category?) {
            let t = Txn(amount: amount, kind: kind, currencyCode: "VND", date: date, category: c, wallet: cash)
            context.insert(t)
            t.allocate(jars: jars, in: context)
        }
        add(1_000_000, .expense, at(9, 10), food)
        add(10_000_000, .income, at(10, 1), nil)
        add(2_000_000, .expense, at(10, 3), food)
        add(500_000, .expense, at(10, 20), food)
        add(3_000_000, .expense, at(10, 12), fun)
        add(100_000, .expense, at(10, 15), nil)
        add(400_000, .expense, at(11, 2), fun) // next month: not in October's report
        return (context, try context.fetch(FetchDescriptor<Txn>()), [cash], jars)
    }

    @Test func totalsAndComparison() throws {
        let (_, txns, wallets, jars) = try book()
        let r = MonthReport(txns: txns, wallets: wallets, jars: jars, month: at(10, 9), calendar: cal)
        #expect(r.income == 10_000_000)
        #expect(r.spent == 5_600_000)
        #expect(r.previousSpent == 1_000_000)
        #expect(r.change == 460)
        #expect(r.saved == 4_400_000)
        #expect(r.savingsRate == 44)
        #expect(!r.isEmpty)
    }

    @Test func byJarAndCategory() throws {
        let (_, txns, wallets, jars) = try book()
        let r = MonthReport(txns: txns, wallets: wallets, jars: jars, month: at(10, 9), calendar: cal)
        #expect(r.byJar.map(\.total) == [3_000_000, 2_500_000, 100_000]) // play, needs, no jar
        #expect(r.byJar.reduce(0) { $0 + $1.total } == r.spent)
        let food = try #require(r.byCategory.first { $0.total == 2_500_000 })
        #expect(food.previous == 1_000_000)
        #expect(r.byCategory.first?.total == 3_000_000)
        #expect(r.byCategory.count == 3)
    }

    @Test func topTrendAndCarryOver() throws {
        let (_, txns, wallets, jars) = try book()
        let r = MonthReport(txns: txns, wallets: wallets, jars: jars, month: at(10, 9), calendar: cal)
        #expect(r.top.map(\.amount) == [3_000_000, 2_000_000, 500_000, 100_000])
        #expect(r.trend.count == 6)
        #expect(r.trend.last?.spent == 5_600_000)
        #expect(r.trend.dropLast().last?.spent == 1_000_000)
        #expect(cal.component(.month, from: r.trend[0].month) == 5)
        // needs: −1tr (Sep) + 8tr − 2.5tr = 4.5tr; play: 2tr − 3tr = −1tr. November's spend is not counted.
        #expect(r.jars.map(\.month.balance) == [4_500_000, -1_000_000])
        #expect(r.jars.map(\.month.start) == [-1_000_000, 0])
        #expect(r.jars.map(\.month.spent) == [2_500_000, 3_000_000])
    }

    @Test func ruleCommentUsesTheNumbers() throws {
        let (_, txns, wallets, jars) = try book()
        let r = MonthReport(txns: txns, wallets: wallets, jars: jars, month: at(10, 9), calendar: cal)
        let text = r.ruleComment(currency: "VND")
        #expect(text.contains("460%"))
        #expect(text.contains("44%"))
        #expect(text.contains(jars[1].name)) // the jar in the red is named

        let empty = MonthReport(txns: txns, wallets: wallets, jars: jars, month: at(3, 1), calendar: cal)
        #expect(empty.isEmpty)
        #expect(!empty.ruleComment(currency: "VND").isEmpty)
    }

    @Test func defaultMonthIsLastMonthWhenItHasData() throws {
        let (_, txns, _, _) = try book()
        let inNov = ReportView.defaultMonth(txns, now: at(11, 6), calendar: cal)
        #expect(cal.component(.month, from: inNov) == 10)
        let inMar = ReportView.defaultMonth(txns, now: at(3, 6), calendar: cal)
        #expect(cal.component(.month, from: inMar) == 3)
    }
}
