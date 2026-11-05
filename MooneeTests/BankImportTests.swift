import Foundation
import SwiftData
import Testing
@testable import Moonee

private final class Token {}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle(for: Token.self).url(forResource: name, withExtension: nil))
    return try Data(contentsOf: url)
}

private func vnDate(_ s: String) -> Date { SePayClient.dateFormatter.date(from: s)! }

struct SePayParsingTests {
    @Test func accounts() throws {
        let page = try SePayClient.decoder.decode(SePayClient.Page<SePayClient.Account>.self, from: fixture("sepay-accounts.json"))
        #expect(page.data.map(\.accountNumber) == ["0001234567", "1900998877"])
        #expect(page.data.map(\.bankShortName) == ["VCB", "TCB"])
        #expect(!page.hasMore)
    }

    @Test func transactionsBecomeDrafts() throws {
        let page = try SePayClient.decoder.decode(SePayClient.Page<SePayClient.Transaction>.self, from: fixture("sepay-transactions.json"))
        #expect(page.data.count == 4)
        let drafts = page.data.compactMap(\.draft) // zero-amount line dropped
        #expect(drafts == [
            BankDraft(externalID: "sepay:7d1c0000-0000-4000-8000-000000000001", account: "0001234567", bank: "VCB", amount: 45_000,
                      kind: .expense, date: vnDate("2026-10-30 08:15:00"), memo: "THANH TOAN QR HIGHLANDS COFFEE"),
            BankDraft(externalID: "sepay:7d1c0000-0000-4000-8000-000000000002", account: "0001234567", bank: "VCB", amount: 15_000_000,
                      kind: .income, date: vnDate("2026-10-31 17:02:11"), memo: "CONG TY ABC TRA LUONG T10"),
            // v1-style string amounts
            BankDraft(externalID: "sepay:7d1c0000-0000-4000-8000-000000000003", account: "1900998877", bank: "TCB", amount: 320_000,
                      kind: .expense, date: vnDate("2026-11-01 09:40:05"), memo: "GRAB*TRIP HCM"),
        ])
        // 08:15 in Hanoi is 01:15 UTC.
        #expect(drafts[0].date.timeIntervalSince1970 == 1_793_322_900)
    }

    @Test func badTokenMessage() {
        #expect(SePayError.http(401).errorDescription == "Token SePay không hợp lệ hoặc đã bị thu hồi.")
    }
}

struct StatementCSVTests {
    @Test func debitCreditWithPreamble() throws {
        let csv = StatementCSV(String(decoding: try fixture("statement-debit-credit.csv"), as: UTF8.self))
        #expect(csv.header.first == "STT")
        #expect(csv.detected == .init(date: 1, memo: 6, amount: nil, debit: 3, credit: 4, reference: 2))
        let drafts = csv.drafts(csv.detected) // totals row has no date and is skipped
        #expect(drafts.map(\.amount) == [55_000, 15_000_000, 1_250_000])
        #expect(drafts.map(\.kind) == [.expense, .income, .expense])
        #expect(drafts.map(\.externalID) == ["csv:5001.0001", "csv:5001.0002", "csv:5001.0003"])
        #expect(drafts[0].memo == "TT QR PHO HA NOI, 2 TO")
        #expect(drafts[0].date == vnDate("2026-10-02 08:01:22"))
    }

    @Test func signedAmountSemicolonQuoted() throws {
        let csv = StatementCSV(String(decoding: try fixture("statement-signed.csv"), as: UTF8.self))
        #expect(csv.detected == .init(date: 0, memo: 1, amount: 2))
        let drafts = csv.drafts(csv.detected)
        #expect(drafts.map(\.memo) == ["Highlands \"Cold Brew\"", "Highlands \"Cold Brew\"", "Hoàn tiền"])
        #expect(drafts.map(\.amount) == [45_000, 45_000, 20_000])
        #expect(drafts.map(\.kind) == [.expense, .expense, .income])
        // Identical lines without a reference stay distinct.
        #expect(Set(drafts.map(\.externalID)).count == 3)
    }

    @Test(arguments: [
        ("1.250.000", 1_250_000), ("1,250,000.00", 1_250_000), ("-50000", -50_000), ("(50,000)", -50_000),
        ("250.000 đ", 250_000), ("+20.000", 20_000), ("", nil), ("-", nil),
    ] as [(String, Int?)])
    func amounts(_ text: String, _ value: Int?) {
        #expect(StatementCSV.amount(text) == value)
    }

    @Test func rowNumberColumnIsNotDebit() {
        #expect(StatementCSV.detect(["No.", "Ngày", "Nợ", "Có", "Diễn giải"]) == .init(date: 1, memo: 4, debit: 2, credit: 3))
    }
}

@MainActor struct BankImporterTests {
    @Test func dedupesAcrossImports() throws {
        let container = try ModelContainer(for: Txn.self, Wallet.self, Category.self, Jar.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let wallet = Wallet(name: "VCB", type: .bank)
        context.insert(wallet)
        let page = try SePayClient.decoder.decode(SePayClient.Page<SePayClient.Transaction>.self, from: fixture("sepay-transactions.json"))
        let drafts = page.data.compactMap(\.draft)

        #expect(try BankImporter.insert(drafts, into: context) { _ in wallet } == 3)
        #expect(try BankImporter.insert(drafts, into: context) { _ in wallet } == 0)
        #expect(try BankImporter.insert(drafts + drafts, into: context) { _ in wallet } == 0)

        let txns = try context.fetch(FetchDescriptor<Txn>(sortBy: [SortDescriptor(\.date)]))
        #expect(txns.count == 3)
        #expect(txns.allSatisfy { $0.source == .bank && $0.category == nil && $0.wallet == wallet })
        #expect(txns[0].rawInput == "THANH TOAN QR HIGHLANDS COFFEE")
        #expect(wallet.balance == -45_000 + 15_000_000 - 320_000)
    }
}
