import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor struct BudgetTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func at(_ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
    }

    func makeContext() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    // MARK: - Jars

    @Test func percentsMustTotal100() {
        #expect(BudgetActions.percentsValid([55, 10, 10, 10, 10, 5]))
        #expect(BudgetActions.percentsValid([100]))
        #expect(!BudgetActions.percentsValid([55, 10, 10]))
        #expect(BudgetActions.percentRemainder([55, 10, 10]) == 25)
        #expect(BudgetActions.percentRemainder([60, 50]) == -10)
        #expect(!BudgetActions.percentsValid([110, -10]))
        #expect(!BudgetActions.percentsValid([]))
    }

    @Test func moveBetweenJarsTouchesJarsOnly() throws {
        let context = try makeContext()
        let a = Jar(icon: "a", colorHex: 0, percent: 50, order: 0), b = Jar(icon: "b", colorHex: 0, percent: 50, order: 1)
        let cash = Wallet(name: "Cash", type: .cash, initialBalance: 100)
        [a, b].forEach(context.insert); context.insert(cash)
        a.initialBalance = 500
        BudgetActions.moveBetweenJars(200, from: a, to: b, jars: [a, b], in: context)
        let l = Ledger(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: [cash], jars: [a, b])
        #expect(l.jarBalance(a.persistentModelID) == 300)
        #expect(l.jarBalance(b.persistentModelID) == 200)
        #expect(l.walletBalance(cash.persistentModelID) == 100)
    }

    // MARK: - Bills

    @Test func markPaidCreatesExpenseAndAdvancesDueDate() throws {
        let context = try makeContext()
        let needs = Jar(key: "jar.essentials", icon: "house", colorHex: 0, percent: 100, order: 0)
        let housing = Category(key: "category.housing", icon: "house", colorHex: 0, jar: needs)
        let bank = Wallet(name: "Bank", type: .bank)
        let rent = Recurring(name: "Rent", amount: 5_000_000, currencyCode: "VND", frequency: .monthly, nextDue: at(11, 5))
        context.insert(needs); context.insert(housing); context.insert(bank); context.insert(rent)
        rent.category = housing
        rent.wallet = bank

        let t = BudgetActions.markPaid(rent, date: at(11, 4), jars: [needs], in: context, calendar: cal)
        #expect(t.kind == .expense && t.amount == 5_000_000 && t.note == "Rent")
        #expect(t.wallet == bank && t.category == housing)
        #expect(t.jar == needs) // allocate pinned the jar
        #expect(rent.nextDue == at(12, 5))
        #expect(rent.lastPaid == at(11, 4))

        // An estimated bill can be paid with the real amount; yearly moves a year.
        rent.frequency = .yearly
        let t2 = BudgetActions.markPaid(rent, amount: 4_800_000, date: at(12, 5), jars: [needs], in: context, calendar: cal)
        #expect(t2.amount == 4_800_000)
        #expect(cal.component(.year, from: rent.nextDue) == 2027)
        #expect(try context.fetchCount(FetchDescriptor<Txn>()) == 2)
    }

    @Test func nextCardDate() {
        #expect(BudgetActions.nextDate(day: 15, from: at(11, 10), calendar: cal) == cal.startOfDay(for: at(11, 15)))
        #expect(BudgetActions.nextDate(day: 5, from: at(11, 10), calendar: cal) == cal.startOfDay(for: at(12, 5)))
        #expect(BudgetActions.nextDate(day: 31, from: at(11, 10), calendar: cal) == cal.startOfDay(for: at(11, 30)))
    }

    // MARK: - Credit card

    @Test func payingCardIsATransferNotASecondExpense() throws {
        let context = try makeContext()
        let play = Jar(key: "jar.play", icon: "s", colorHex: 0, percent: 100, order: 0)
        let shopping = Category(key: "category.shopping", icon: "cart", colorHex: 0, jar: play)
        let bank = Wallet(name: "Bank", type: .bank, initialBalance: 10_000_000)
        let card = Wallet(name: "Visa", type: .credit, creditLimit: 20_000_000)
        [play].forEach(context.insert); context.insert(shopping); context.insert(bank); context.insert(card)
        play.initialBalance = 3_000_000

        let swipe = Txn(amount: 2_000_000, kind: .expense, category: shopping, wallet: card)
        context.insert(swipe)
        swipe.allocate(jars: [play], in: context)
        let pay = BudgetActions.payCard(card, amount: 2_000_000, from: bank, jars: [play], in: context)
        #expect(pay.kind == .transfer && pay.wallet == bank && pay.toWallet == card)

        let l = Ledger(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: [bank, card], jars: [play])
        #expect(l.walletBalance(card.persistentModelID) == 0)           // debt cleared
        #expect(l.walletBalance(bank.persistentModelID) == 8_000_000)
        #expect(l.jarBalance(play.persistentModelID) == 1_000_000)      // charged once, at the swipe
    }

    // MARK: - Reminders (pure planner)

    typealias P = ReminderPlanner

    @Test func billRemindsBeforeAndOnDueDay() {
        let plan = P.plan(bills: [.init(name: "Rent", due: at(11, 10), remindDaysBefore: 3)],
                          settings: .init(level: .low), now: at(11, 5), calendar: cal)
        #expect(plan.map(\.date) == [at(11, 7, 9), at(11, 10, 9)])
        #expect(plan.allSatisfy { $0.kind == .bill && $0.items == ["Rent"] })
    }

    @Test func levelsFilterKinds() {
        let jars = [P.JarState(id: "play", name: "Play", level: .warning)]
        let low = P.plan(jars: jars, settings: .init(level: .low), now: at(11, 5), calendar: cal)
        #expect(low.isEmpty) // 80% and reports are medium+, the evening nudge is high
        let medium = P.plan(jars: jars, settings: .init(level: .medium), now: at(11, 5), calendar: cal)
        #expect(medium.contains { $0.kind == .jarWarning })
        #expect(medium.contains { $0.kind == .weeklyReport })
        #expect(!medium.contains { $0.kind == .dailyLog })
        let high = P.plan(settings: .init(level: .high), now: at(11, 5), calendar: cal)
        #expect(high.contains { $0.kind == .dailyLog })
    }

    @Test func sameKindSameDayIsGrouped() {
        let plan = P.plan(bills: [.init(name: "Internet", due: at(11, 8), remindDaysBefore: 0),
                                  .init(name: "Water", due: at(11, 8), remindDaysBefore: 0)],
                          jars: [.init(id: "a", name: "Play", level: .over), .init(id: "b", name: "Giving", level: .negative)],
                          settings: .init(level: .low), now: at(11, 5), calendar: cal)
        #expect(plan.count == 2)
        #expect(plan.first { $0.kind == .bill }?.items == ["Internet", "Water"])
        let jar = plan.first { $0.kind == .jarOver }
        #expect(jar?.items == ["Play", "Giving"])
        #expect(jar?.keys == ["jar.over.a.2026-11", "jar.over.b.2026-11"])
        #expect(jar?.date == at(11, 5)) // right away
    }

    @Test func dailyCapKeepsHighestPriority() {
        // Medium allows 3 a day. On Nov 1 (a Sunday): bill, debt, monthly report, weekly report → the weekly report drops.
        let plan = P.plan(bills: [.init(name: "Rent", due: at(11, 1), remindDaysBefore: 0)],
                          debts: [.init(person: "Nam", due: at(11, 1))],
                          settings: .init(level: .medium, horizonDays: 1), now: at(11, 1, 6), calendar: cal)
        #expect(plan.map(\.kind) == [.bill, .debt, .monthlyReport])
        // Notifications already delivered today count against the cap.
        let later = P.plan(bills: [.init(name: "Rent", due: at(11, 1), remindDaysBefore: 0)],
                           debts: [.init(person: "Nam", due: at(11, 1))],
                           settings: .init(level: .medium, horizonDays: 1), now: at(11, 1, 6), deliveredToday: 2, calendar: cal)
        #expect(later.map(\.kind) == [.bill])
    }

    @Test func quietHoursDelay() {
        // 23:00 jar alert waits until 07:00 the next morning.
        let plan = P.plan(jars: [.init(id: "a", name: "Play", level: .over)], settings: .init(level: .low),
                          now: at(11, 5, 23), calendar: cal)
        #expect(plan.first?.date == at(11, 6, 7))
        // 06:00 also waits until 07:00 the same day; same-day quiet window (13:00–14:00) works too.
        let s = P.Settings(quietStart: 13 * 60, quietEnd: 14 * 60)
        #expect(P.outOfQuietHours(at(11, 5, 13, 30), s, cal) == at(11, 5, 14))
        #expect(P.outOfQuietHours(at(11, 5, 6), P.Settings(), cal) == at(11, 5, 7))
        #expect(P.outOfQuietHours(at(11, 5, 12), P.Settings(), cal) == at(11, 5, 12))
    }

    @Test func jarAlertsFireOncePerMonth() {
        let jars = [P.JarState(id: "a", name: "Play", level: .warning)]
        let sent: Set<String> = ["jar.warn.a.2026-11"]
        #expect(P.plan(jars: jars, settings: .init(level: .medium, horizonDays: 1), now: at(11, 5), sent: sent, calendar: cal).isEmpty)
        // Going over still alerts after the 80% one; an over alert already sent covers a later 80% state.
        let over = [P.JarState(id: "a", name: "Play", level: .over)]
        #expect(P.plan(jars: over, settings: .init(level: .medium, horizonDays: 1), now: at(11, 5), sent: sent, calendar: cal).count == 1)
        #expect(P.plan(jars: jars, settings: .init(level: .medium, horizonDays: 1), now: at(11, 5), sent: ["jar.over.a.2026-11"], calendar: cal).isEmpty)
    }
}
