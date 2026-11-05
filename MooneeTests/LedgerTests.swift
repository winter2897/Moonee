import Foundation
import SwiftData
import Testing
@testable import Moonee

struct LedgerTests {
    typealias L = Ledger<String>
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()
    let percents: [(String, Int)] = [("needs", 55), ("invest", 10), ("save", 10), ("grow", 10), ("play", 10), ("give", 5)]

    func day(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }
    var november: DateInterval { cal.dateInterval(of: .month, for: day(11, 15))! }

    func e(_ kind: TxKind, _ amount: Int, _ date: Date? = nil, wallet: String? = "cash", to: String? = nil,
           jar: String? = nil, toJar: String? = nil, debt: String? = nil, splits: [String: Int] = [:]) -> L.Entry {
        L.Entry(kind: kind, amount: amount, date: date ?? day(11, 10), wallet: wallet, toWallet: to,
                jar: jar, toJar: toJar, debt: debt, splits: splits)
    }

    @Test func splitByPercentSumsExactly() {
        let s = L.split(1_000_001, by: percents)
        #expect(s.values.reduce(0, +) == 1_000_001)
        #expect(s["needs"] == 550_001) // remainder to the largest jar
        #expect(s["give"] == 50_000)
        #expect(L.split(100, by: [("a", 0)]).isEmpty)
    }

    @Test func walletAndJarBalances() {
        let l = L(entries: [
            e(.income, 10_000_000),
            e(.expense, 45_000, jar: "needs"),
            e(.expense, 30_000), // no jar: wallet only
        ], walletOpening: ["cash": 500_000], jarPercents: percents)
        #expect(l.walletBalance("cash") == 500_000 + 10_000_000 - 45_000 - 30_000)
        #expect(l.jarBalance("needs") == 5_500_000 - 45_000)
        #expect(l.jarBalance("play") == 1_000_000)
    }

    @Test func manualSplitOverridesPercents() {
        let l = L(entries: [e(.income, 5_000_000, splits: ["invest": 5_000_000])], jarPercents: percents)
        #expect(l.jarBalance("invest") == 5_000_000)
        #expect(l.jarBalance("needs") == 0)
    }

    @Test func jarsCarryOverAndCardNumbers() {
        let l = L(entries: [
            e(.income, 1_000_000, day(10, 1), splits: ["play": 1_000_000]),
            e(.expense, 400_000, day(10, 20), jar: "play"),          // October leaves 600k
            e(.income, 2_000_000, day(11, 1), splits: ["play": 200_000, "needs": 1_800_000]),
            e(.jarTransfer, 100_000, day(11, 3), wallet: nil, jar: "needs", toJar: "play"),
            e(.expense, 450_000, day(11, 5), jar: "play"),
            e(.expense, 1, day(12, 1), jar: "play"),                 // next month: not in November's card
        ], jarOpening: ["play": 50_000], jarPercents: percents)
        let m = l.jarMonth("play", in: november)
        #expect(m.start == 650_000)
        #expect(m.added == 300_000)
        #expect(m.spent == 450_000)
        #expect(m.budget == 950_000)
        #expect(abs(m.progress - 450_000.0 / 950_000) < 1e-9)
        #expect(m.balance == 650_000 + 300_000 - 450_000 - 1)
        #expect(l.jarBalance("needs") == 1_700_000)
        #expect(l.walletBalance("cash") == 3_000_000 - 850_001) // jar transfer moved no wallet money
    }

    @Test func overspentAndEmptyJarProgress() {
        let l = L(entries: [e(.expense, 10, jar: "play")])
        #expect(l.jarMonth("play", in: november).progress == .infinity)
        #expect(l.jarMonth("give", in: november).progress == 0)
        #expect(l.jarBalance("play") == -10)
    }

    @Test func creditCardSwipeAndPayment() {
        let l = L(entries: [
            e(.income, 10_000_000, wallet: "bank"),
            e(.expense, 2_000_000, wallet: "card", jar: "needs"),  // swipe: jar −, card debt +
            e(.transfer, 2_000_000, wallet: "bank", to: "card"),   // pay the card: not a second expense
        ], jarPercents: [("needs", 100)])
        #expect(l.walletBalance("card") == 0)
        #expect(l.walletBalance("bank") == 8_000_000)
        #expect(l.jarBalance("needs") == 8_000_000)
        #expect(l.netWorth() == 8_000_000)

        let unpaid = L(entries: [e(.expense, 300_000, wallet: "card", jar: "needs")])
        #expect(unpaid.walletBalance("card") == -300_000)
        #expect(unpaid.netWorth() == -300_000)
    }

    @Test func lendBorrowRepayNeverTouchJars() {
        let l = L(entries: [
            e(.income, 10_000_000),
            e(.lend, 2_000_000, debt: "nam"),
            e(.repay, 500_000, debt: "nam"),      // Nam pays me back: money in
            e(.borrow, 5_000_000, debt: "mom"),
            e(.repay, 1_000_000, debt: "mom"),    // I pay Mom back: money out
        ], jarPercents: percents, debtDirections: ["nam": .lent, "mom": .borrowed])
        #expect(l.walletBalance("cash") == 10_000_000 - 2_000_000 + 500_000 + 5_000_000 - 1_000_000)
        #expect(l.debtRemaining["nam"] == 1_500_000)
        #expect(l.debtRemaining["mom"] == 4_000_000)
        #expect(l.jarBalances.values.reduce(0, +) == 10_000_000)
        // Lending or borrowing does not change what you are worth.
        #expect(l.netWorth() == 10_000_000)
    }

    @Test func netWorthAddsAssets() {
        let l = L(entries: [e(.income, 1_000_000)], walletOpening: ["cash": 0, "bank": 2_000_000])
        #expect(l.netWorth(assets: 170_000_000) == 173_000_000)
    }

    @MainActor @Test func swiftDataAdapterUsesCategoryJarAndDebtDirection() throws {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let jar = Jar(key: "jar.essentials", icon: "house.fill", colorHex: 0, percent: 100, order: 0)
        let food = Category(key: "category.food", icon: "fork.knife", colorHex: 0, jar: jar)
        let cash = Wallet(name: "Cash", type: .cash, initialBalance: 100_000)
        let debt = Debt(person: "Nam", direction: .lent)
        context.insert(jar); context.insert(food); context.insert(cash); context.insert(debt)
        let pho = Txn(amount: 45_000, kind: .expense, category: food, wallet: cash)
        let repaid = Txn(amount: 20_000, kind: .repay, wallet: cash)
        repaid.debt = debt
        [pho, repaid].forEach { context.insert($0) }

        let l = Ledger(txns: [pho, repaid], wallets: [cash], jars: [jar])
        #expect(l.jarBalance(jar.persistentModelID) == -45_000)
        #expect(l.walletBalance(cash.persistentModelID) == 100_000 - 45_000 + 20_000)
        #expect(food.name == "Food & Drinks")
    }
}

struct MoneyTests {
    @Test func minorUnitsPerCurrency() {
        #expect(Money(major: 12.5, "USD").minor == 1_250)
        #expect(Money(major: 45_000, "VND").minor == 45_000)
        #expect(Money(1_250, "USD").major == Decimal(string: "12.5"))
    }

    @Test func formatsWithLocale() {
        #expect(Money(250_000, "VND").formatted(locale: Locale(identifier: "vi_VN")) == "250.000\u{a0}₫")
        #expect(Money(1_250, "USD").formatted(locale: Locale(identifier: "en_US")) == "$12.50")
    }
}
