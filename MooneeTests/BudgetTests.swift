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
        ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
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

    @Test func billOnThe31stKeepsItsDay() throws {
        let context = try makeContext()
        let date = { (y: Int, m: Int, d: Int) in self.cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
        let rent = Recurring(name: "Rent", amount: 100, nextDue: date(2027, 1, 31))
        context.insert(rent)
        var dues: [Date] = []
        for _ in 0..<4 {
            BudgetActions.markPaid(rent, date: rent.nextDue, jars: [], in: context, calendar: cal)
            dues.append(rent.nextDue)
        }
        // Short months use their last day; the 31st comes back as soon as the month has one.
        #expect(dues == [date(2027, 2, 28), date(2027, 3, 31), date(2027, 4, 30), date(2027, 5, 31)])
        #expect(rent.dueDay == 31)

        // Yearly on Feb 29: Feb 28 in common years, Feb 29 again in a leap year.
        #expect(BudgetActions.nextDue(after: date(2027, 2, 28), .yearly, day: 29, calendar: cal) == date(2028, 2, 29))
        // A bill due on the 30th stays on the 30th after February.
        #expect(BudgetActions.nextDue(after: date(2027, 2, 28), .monthly, day: 30, calendar: cal) == date(2027, 3, 30))
        #expect(BudgetActions.nextDue(after: date(2027, 3, 31), .weekly, day: 31, calendar: cal) == date(2027, 4, 7))
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

    @Test func freshUserAtMediumGetsReminders() {
        // Right after onboarding: a rent bill and a payday, nothing logged, no jar in trouble, no debts.
        let now = at(11, 25, 10)
        let plan = P.plan(bills: [.init(name: "Rent", due: at(12, 5), remindDaysBefore: 3)],
                          paydays: [.init(name: "Salary", due: at(11, 30), title: "Salary in yet?", body: "Tap Received.")],
                          settings: .init(level: .medium), now: now, calendar: cal)
        #expect(plan.allSatisfy { $0.date >= now && $0.date < at(12, 9, 0) })
        #expect(plan.contains { $0.kind == .weeklyReport && $0.date == at(11, 29, 19) })   // Sunday evening
        #expect(plan.contains { $0.kind == .payday && $0.date == at(11, 30, 9) })
        #expect(plan.contains { $0.kind == .monthlyReport && $0.date == at(12, 1, 9) })   // month end → new month
        #expect(plan.filter { $0.kind == .bill }.map(\.date) == [at(12, 2, 9), at(12, 5, 9)])
        #expect(!plan.contains { $0.kind == .dailyLog }) // the evening nudge is "High" (spec §3.4)
        #expect(plan.count <= P.maxPending)
        // Even with no bills at all, the first weekly report is at most a week away.
        #expect(P.plan(settings: .init(level: .medium), now: now, calendar: cal).first?.date == at(11, 29, 19))
    }

    @Test func debtReminders() {
        let plan = P.plan(debts: [.init(person: "Nam", due: at(11, 10), amount: "300k"),                 // lent: on the day
                                  .init(person: "Lan", due: at(11, 12), amount: "2tr", owedByMe: true),  // owed: day before too
                                  .init(person: "Hùng", due: nil, amount: "500k", since: at(10, 30))], // no date: every 2 weeks
                          settings: .init(level: .medium), now: at(11, 5, 10), calendar: cal)
        let debts = plan.filter { $0.kind == .debt || $0.kind == .debtNudge }
        #expect(debts.map(\.date) == [at(11, 10, 9), at(11, 11, 9), at(11, 12, 9), at(11, 13, 9)])
        #expect(debts.map(\.items) == [["Nam"], ["Lan"], ["Lan"], ["Hùng"]])
        #expect(debts.last?.kind == .debtNudge)
        #expect(debts[0].body?.contains("300k") == true)
        #expect(debts[1].body?.contains("Tomorrow") == true)
        // Past its due date: the nudge goes on every two weeks from that day. Low level: no debt reminders.
        let overdue = P.plan(debts: [.init(person: "Nam", due: at(10, 25), amount: "300k")], settings: .init(level: .medium),
                             now: at(11, 5, 10), calendar: cal)
        #expect(overdue.first { $0.kind == .debtNudge }?.date == at(11, 8, 9))
        #expect(!P.plan(debts: [.init(person: "Nam", due: at(11, 10))], settings: .init(level: .low), now: at(11, 5), calendar: cal)
            .contains { $0.kind == .debt })
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
