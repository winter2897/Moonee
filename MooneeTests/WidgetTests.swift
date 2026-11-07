import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor struct WidgetTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func at(_ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h))!
    }

    /// Two jars, 10tr salary split 60/40, two expenses today and one yesterday.
    func makeBooks() throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let needs = Jar(key: "jar.essentials", icon: "house", colorHex: 0xEAB308, percent: 60, order: 0)
        let play = Jar(key: "jar.play", icon: "sparkles", colorHex: 0xF472B6, percent: 40, order: 1)
        let food = Category(key: "category.food", icon: "fork.knife", colorHex: 0, jar: needs)
        let fun = Category(key: "category.entertainment", icon: "gamecontroller", colorHex: 0, jar: play)
        let cash = Wallet(name: "Cash", type: .cash)
        [needs, play].forEach(context.insert); [food, fun].forEach(context.insert); context.insert(cash)
        func add(_ amount: Int, _ kind: TxKind, _ date: Date, _ category: Moonee.Category? = nil) {
            let t = Txn(amount: amount, kind: kind, currencyCode: "VND", date: date, category: category, wallet: cash)
            context.insert(t)
            t.allocate(jars: [needs, play], in: context)
        }
        add(10_000_000, .income, at(11, 1))
        add(200_000, .expense, at(11, 6), fun)
        add(50_000, .expense, at(11, 7, 8), food)
        add(30_000, .expense, at(11, 7, 19), fun)
        try context.save()
        return context
    }

    @Test func snapshotHasTheBudgetTabsNumbers() throws {
        let context = try makeBooks()
        let now = at(11, 7, 20)
        let s = WidgetSnapshot(context, now: now, calendar: cal, hidden: true)
        let facts = BudgetFacts(context, now: now, calendar: cal)
        #expect(s.left == facts.left && s.budget == facts.budget && s.spent == facts.spent)
        #expect(s.left == 10_000_000 - 280_000)
        #expect(s.spentToday == 80_000)
        #expect(s.hidden)
        #expect(s.jars.map(\.colorHex) == [0xEAB308, 0xF472B6])
        #expect(s.topJars.first?.spent == 230_000) // play spent most
    }

    @Test func rollsOverMidnightAndMonthEnd() throws {
        let s = WidgetSnapshot(try makeBooks(), now: at(11, 7, 20), calendar: cal)
        #expect(s.at(at(11, 7, 23), calendar: cal) == s)
        let tomorrow = s.at(at(11, 8, 0), calendar: cal)
        #expect(tomorrow.spentToday == 0 && tomorrow.left == s.left)
        // December: each jar starts from its balance (carry-over), nothing spent yet.
        let december = s.at(at(12, 1, 0), calendar: cal)
        #expect(december.spent == 0 && december.left == s.jars.reduce(0) { $0 + $1.balance })
    }

    @Test func refreshWritesOnlyWhenTheNumbersChange() throws {
        let context = try makeBooks()
        let url = FileManager.default.temporaryDirectory.appending(path: "widget-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        WidgetSync.refresh(context, to: url)
        let first = try #require(WidgetSnapshot.load(from: url))
        let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        WidgetSync.refresh(context, to: url) // nothing changed
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == written)
        context.insert(Txn(amount: 1_000, kind: .expense, currencyCode: "VND", date: .now))
        WidgetSync.refresh(context, to: url)
        #expect(WidgetSnapshot.load(from: url)?.spentToday == first.spentToday + 1_000)
    }
}
