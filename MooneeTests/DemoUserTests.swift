import Foundation
import SwiftData
import Testing
@testable import Moonee

/// The sample user (Account › Data "Load sample data") builds books that add up, whatever day it is loaded.
@MainActor struct DemoUserTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func seeded(now: Date) throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let defaults = UserDefaults(suiteName: "DemoUserTests")!
        defaults.removePersistentDomain(forName: "DemoUserTests")
        DemoUser.seed(context, now: now, calendar: Self.calendar, defaults: defaults)
        try context.save()
        #expect(defaults.string(forKey: Prefs.profileName) == "Minh")
        #expect(defaults.string(forKey: Prefs.advisorLevel) == AdvisorLevel.suggest.rawValue)
        #expect(defaults.bool(forKey: Prefs.onboardingDone))
        #expect(!Terms.needsConsent(accepted: defaults.integer(forKey: Prefs.termsVersion)))
        return context
    }

    static let days = ["2026-11-07T12:00:00+07:00", "2026-03-01T08:00:00+07:00", "2026-01-31T22:00:00+07:00",
                       "2026-05-04T12:00:00+07:00", "2026-08-05T07:30:00+07:00", "2026-12-25T18:00:00+07:00"]

    @Test(arguments: days) func booksAddUp(_ day: String) throws {
        let now = try Date(day, strategy: .iso8601)
        let context = try seeded(now: now)
        let txns = try context.fetch(FetchDescriptor<Txn>())
        let wallets = try context.fetch(FetchDescriptor<Wallet>())
        let jars = try context.fetch(FetchDescriptor<Jar>())
        let l = Ledger(txns: txns, wallets: wallets, jars: jars)

        #expect(txns.count > 250)
        #expect(txns.allSatisfy { $0.date <= now })
        #expect(txns.filter { $0.kind == .expense }.allSatisfy { $0.jar != nil }) // every spend comes out of a jar
        for w in wallets where w.type != .credit { #expect(l.walletBalance(w.persistentModelID) >= 0, "\(w.name)") }
        for j in jars { #expect(l.jarBalance(j.persistentModelID) >= 0, "\(j.name)") }
        #expect(l.unallocated > 0) // the side income waits for the advisor's plan
        #expect(l.budgetBalance == jars.reduce(0) { $0 + l.jarBalance($1.persistentModelID) } + l.unallocated)
        let card = try #require(wallets.first { $0.type == .credit })
        #expect(l.walletBalance(card.persistentModelID) < 0) // some balance owed

        // 3 salaries, each split into the jars in full.
        let salaries = txns.filter { $0.kind == .income && $0.category?.key == "category.salary" }
        #expect(salaries.count == 3)
        for s in salaries { #expect((s.splits ?? []).reduce(0) { $0 + $1.amount } == s.amount) }

        // Debt book: Tuấn partly repaid, Nam settled, chị Lan owed by me, Hoa with no date.
        let left = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Debt>()).map { ($0.person, l.debtRemaining[$0.persistentModelID] ?? 0) })
        #expect(left == ["Tuấn": 1_500_000, "Nam": 0, "chị Lan": 3_000_000, "Hoa": 500_000])

        // Last month the Play jar went slightly over.
        let thisMonth = Self.calendar.dateInterval(of: .month, for: now)!
        let lastMonth = Self.calendar.dateInterval(of: .month, for: thisMonth.start.addingTimeInterval(-1))!
        let play = try #require(jars.first { $0.key == "jar.play" })
        let m = l.jarMonth(play.persistentModelID, in: lastMonth)
        #expect(m.spent > m.budget && m.spent - m.budget < 600_000)

        // Bills: one overdue, one due soon, the rent paid.
        let bills = try context.fetch(FetchDescriptor<Recurring>())
        #expect(bills.contains { !$0.isIncome && $0.nextDue < Self.calendar.startOfDay(for: now) })
        #expect(bills.first { $0.name == "Tiền nhà" }?.lastPaid != nil)
        #expect(bills.first { $0.isIncome }.map { $0.nextDue >= Self.calendar.startOfDay(for: now) } == true) // next payday (today before 9:00)

        #expect(try context.fetchCount(FetchDescriptor<ChatThread>()) == 3)
        #expect(txns.filter { $0.chatMessage != nil }.count >= 5)
        #expect(try context.fetchCount(FetchDescriptor<Asset>()) == 3)
    }

    @Test func deterministic() throws {
        let now = try Date("2026-11-07T12:00:00+07:00", strategy: .iso8601)
        func summary() throws -> [Int] {
            let txns = try seeded(now: now).fetch(FetchDescriptor<Txn>())
            return [txns.count, txns.reduce(0) { $0 + $1.amount }]
        }
        #expect(try summary() == summary())
    }
}
