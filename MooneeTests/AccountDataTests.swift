import Foundation
import SwiftData
import Testing
@testable import Moonee

@MainActor
struct AccountDataTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    @Test func feedbackMailGoesToTheOwnerWithTheFacts() throws {
        let url = FeedbackMail.mailto
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "mailto" && parts.path == "haiquantran2897@gmail.com")
        #expect(parts.queryItems?.first { $0.name == "subject" }?.value == "Moonee feedback (\(AppInfo.number) (\(AppInfo.build)))")
        let body = try #require(parts.queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("iOS") && body.contains("Device: ") && body.contains("Language: "))
    }

    @Test func csvExportUsesFixedEnglishHeadersAndKeys() throws {
        let container = try container()
        let context = container.mainContext
        Seed.ifNeeded(context)
        let food = try #require(try context.fetch(FetchDescriptor<Moonee.Category>()).first { $0.key == "category.food" })
        let wallet = try #require(try context.fetch(FetchDescriptor<Wallet>()).first)
        let utc = TimeZone(identifier: "UTC")!

        let pho = Txn(amount: 45_000, kind: .expense, date: Date(timeIntervalSince1970: 1_762_300_800), note: "phở, \"đặc biệt\"",
                      category: food, wallet: wallet)
        pho.currencyCode = "VND"
        let coffee = Txn(amount: 1250, kind: .expense, date: Date(timeIntervalSince1970: 1_762_387_200), note: "=HYPERLINK(\"x\")")
        coffee.currencyCode = "USD"
        [pho, coffee].forEach(context.insert)

        let lines = CSVExport.csv([coffee, pho], timeZone: utc).components(separatedBy: "\r\n")
        #expect(lines[0] == "date,type,amount,currency,category,wallet,to_wallet,jar,to_jar,person,note")
        #expect(lines[1] == "2025-11-05 00:00:00,expense,45000,VND,category.food,\(wallet.name),,,,,\"phở, \"\"đặc biệt\"\"\"")
        #expect(lines[2] == "2025-11-06 00:00:00,expense,12.5,USD,,,,,,,\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(lines.count == 4 && lines[3].isEmpty)
    }

    @Test func csvFieldLeavesPlainTextAndNegativeNumbersAlone() {
        #expect(CSVExport.field("Cash wallet") == "Cash wallet")
        #expect(CSVExport.field("-12.5") == "-12.5")
        #expect(CSVExport.field("@me") == "'@me")
        #expect(CSVExport.field("a\nb") == "\"a\nb\"")
    }

    @Test func deleteAllRemovesEverythingAndReseeds() throws {
        let container = try container()
        let context = container.mainContext
        Seed.ifNeeded(context)
        let jar = try #require(try context.fetch(FetchDescriptor<Jar>()).first)
        jar.customName = "Mine"
        let wallet = Wallet(name: "Bank", type: .bank)
        context.insert(wallet)
        let txn = Txn(amount: 100, kind: .income, wallet: wallet)
        context.insert(txn)
        txn.allocate(jars: try context.fetch(FetchDescriptor<Jar>()), in: context)
        context.insert(Goal(name: "Trip", target: 1000))
        context.insert(Debt(person: "An", direction: .lent))
        try context.save()

        let defaults = try #require(UserDefaults(suiteName: "AccountDataTests"))
        defaults.set("Quân", forKey: Prefs.profileName)

        try DataReset.deleteAll(context, defaults: defaults, domain: "AccountDataTests")

        #expect(try context.fetchCount(FetchDescriptor<Txn>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<IncomeSplit>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Goal>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Debt>()) == 0)
        let jars = try context.fetch(FetchDescriptor<Jar>())
        #expect(jars.count == Seed.defaultJars.count)
        #expect(jars.allSatisfy { $0.customName == nil })
        #expect(try context.fetch(FetchDescriptor<Wallet>()).map(\.type) == [.cash])
        #expect(defaults.string(forKey: Prefs.profileName) == nil)
    }

    @Test func lockComesBackOnlyAfterTheChosenTime() {
        let away = Date(timeIntervalSince1970: 0)
        #expect(!AppLock.shouldLock(enabled: false, backgroundedAt: away, now: away.addingTimeInterval(9999), afterMinutes: 0))
        #expect(!AppLock.shouldLock(enabled: true, backgroundedAt: nil, afterMinutes: 0))
        #expect(AppLock.shouldLock(enabled: true, backgroundedAt: away, now: away, afterMinutes: 0))
        #expect(!AppLock.shouldLock(enabled: true, backgroundedAt: away, now: away.addingTimeInterval(299), afterMinutes: 5))
        #expect(AppLock.shouldLock(enabled: true, backgroundedAt: away, now: away.addingTimeInterval(300), afterMinutes: 5))
    }
}
