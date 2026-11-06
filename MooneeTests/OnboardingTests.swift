import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor struct OnboardingTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func seeded() throws -> ModelContext {
        let context = ModelContext(try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        Seed.ifNeeded(context)
        return context
    }

    var vnd: ParserContext {
        var p = ParserContext()
        p.currency = "VND"
        return p
    }

    @Test func typedAmounts() {
        #expect(OnboardingBook.amount("15tr", context: vnd) == 15_000_000)
        #expect(OnboardingBook.amount("2000000", context: vnd) == 2_000_000)
        #expect(OnboardingBook.amount("2.000.000", context: vnd) == 2_000_000)
        #expect(OnboardingBook.amount("", context: vnd) == nil)
        #expect(OnboardingBook.amount("abc", context: vnd) == nil)
    }

    @Test func incomeRangesFollowCurrency() {
        let vndRanges = OnboardingBook.incomeRanges(currency: "VND")
        #expect(vndRanges.map(\.mid) == [7_000_000, 15_000_000, 30_000_000, 50_000_000])
        #expect(OnboardingBook.incomeRanges(currency: "USD").map(\.mid) == [150_000, 300_000, 600_000, 1_000_000]) // cents
        #expect(OnboardingBook.incomeRanges(currency: "THB").map(\.mid) == [10_000, 22_000, 45_000, 80_000].map { Money(major: Decimal($0), "THB").minor })
        #expect(OnboardingBook.incomeRanges(currency: "LAK").map(\.mid) == [2_000_000, 4_500_000, 9_000_000, 15_000_000].map { Money(major: Decimal($0), "LAK").minor })
    }

    @Test func walletsReuseSeededCashAndStoreCardDebtNegative() throws {
        let context = try seeded()
        OnboardingBook.saveWallets([
            .init(type: .cash, name: "", amount: 2_000_000),
            .init(type: .bank, name: "", amount: 10_000_000),
            .init(type: .credit, name: "", amount: 3_000_000),
        ], in: context)
        let wallets = try context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.order)]))
        #expect(wallets.count == 3) // the seeded cash wallet is reused, not duplicated
        #expect(wallets.filter { $0.type == .cash }.map(\.initialBalance) == [2_000_000])
        #expect(wallets.first { $0.type == .bank }?.initialBalance == 10_000_000)
        #expect(wallets.first { $0.type == .credit }?.initialBalance == -3_000_000)
        #expect(Set(wallets.map(\.order)).count == 3)
        let ledger = Ledger(txns: [], wallets: wallets, jars: [])
        #expect(ledger.netWorth() == 9_000_000)
    }

    @Test func billsBecomeMonthlyRecurrings() throws {
        let context = try seeded()
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
        let saved = OnboardingBook.saveBills([
            .init(name: "Rent", amount: 5_000_000, day: 5),
            .init(name: "Internet", amount: 250_000, day: 15),
            .init(name: "Water", amount: 0, day: 10), // no amount: skipped
        ], now: now, calendar: cal, in: context)
        #expect(saved.map(\.name) == ["Rent", "Internet"])
        let rent = try #require(saved.first)
        #expect(rent.frequency == .monthly)
        #expect(rent.category?.key == "category.housing")
        #expect(rent.wallet?.type == .cash)
        #expect(cal.component(.day, from: rent.nextDue) == 5)
        #expect(cal.component(.month, from: rent.nextDue) == 12) // 5 Nov has passed
        #expect(cal.component(.month, from: saved[1].nextDue) == 11)
        #expect(try context.fetchCount(FetchDescriptor<Recurring>()) == 2)
    }

    @Test func jarProposal() {
        let keys = ["jar.essentials", "jar.investing", "jar.savings", "jar.growth", "jar.play", "jar.giving"]
        let base = [55, 10, 10, 10, 10, 5]
        func propose(income: Int?, regular: Bool?, bills: Int) -> [Int] {
            OnboardingBook.proposePercents(keys: keys, current: base, monthlyIncome: income, regular: regular, billsTotal: bills)
        }
        #expect(propose(income: nil, regular: nil, bills: 0) == base)
        #expect(propose(income: 20_000_000, regular: true, bills: 5_000_000) == base) // bills 25% + 15 = 40 < 55
        #expect(propose(income: 20_000_000, regular: false, bills: 0) == [55, 10, 15, 10, 5, 5])
        // bills 50% → essentials 65, 10 points from Play then Growth, none under 5.
        #expect(propose(income: 10_000_000, regular: true, bills: 5_000_000) == [65, 10, 10, 5, 5, 5])
        // Bills above income: capped at 80, still totals 100.
        let heavy = propose(income: 10_000_000, regular: false, bills: 12_000_000)
        #expect(heavy[0] == 75 || heavy[0] == 80)
        #expect(heavy.reduce(0, +) == 100)
        #expect(heavy.allSatisfy { $0 >= 5 })
    }

    @Test func applyJarsWritesPercentsAndLeavesOpeningMoneyUnallocated() throws {
        let context = try seeded()
        OnboardingBook.saveWallets([.init(type: .cash, name: "", amount: 12_000_000),
                                    .init(type: .credit, name: "", amount: 2_000_000)], in: context)
        let jars = try context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))
        OnboardingBook.applyJars([60, 10, 10, 10, 5, 5], to: jars, in: context)
        #expect(jars.map(\.percent) == [60, 10, 10, 10, 5, 5])
        let ledger = Ledger(txns: try context.fetch(FetchDescriptor<Txn>()), wallets: try context.fetch(FetchDescriptor<Wallet>()), jars: jars)
        // Existing money is split once on the Budget tab (rule A.4), not here.
        #expect(jars.allSatisfy { ledger.jarBalance($0.persistentModelID) == 0 })
        #expect(ledger.unallocated == 10_000_000) // 12tr − 2tr card debt

        OnboardingBook.applyJars([50, 10], to: jars, in: context) // invalid: nothing changes
        #expect(jars[0].percent == 60)
    }

    @Test func suggestedMode() {
        #expect(OnboardingBook.suggestedMode(appleAvailable: true, localFits: true, language: "en") == .onDevice)
        #expect(OnboardingBook.suggestedMode(appleAvailable: true, localFits: true, language: "vi") == .local)
        #expect(OnboardingBook.suggestedMode(appleAvailable: true, localFits: true, language: "th") == .local)
        #expect(OnboardingBook.suggestedMode(appleAvailable: true, localFits: false, language: "vi") == .onDevice)
        #expect(OnboardingBook.suggestedMode(appleAvailable: false, localFits: true, language: "en") == .local)
        #expect(OnboardingBook.suggestedMode(appleAvailable: false, localFits: false, language: "en") == .byok)
    }
}
