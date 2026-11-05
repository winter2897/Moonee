import Foundation
import Testing
@testable import Moonee

private final class Token {}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle(for: Token.self).url(forResource: name, withExtension: nil))
    return try Data(contentsOf: url)
}

private func vnDate(_ s: String) -> Date { StatementCSV.date(s)! }

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

