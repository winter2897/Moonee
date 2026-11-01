import Foundation
import Testing
@testable import Moonee

struct ClassifierTests {
    let expense = ["Ăn uống", "Di chuyển", "Khác"]
    let income = ["Lương"]
    let items = [
        Classifier.Item(id: 1, text: "cf sáng", amount: 35_000, kind: .expense),
        Classifier.Item(id: 2, text: "grab về nhà", amount: 60_000, kind: .expense),
        Classifier.Item(id: 3, text: "lương T10", amount: 20_000_000, kind: .income),
    ]

    @Test func promptListsCategoriesAndItems() {
        let p = Classifier.prompt(items: items, expense: expense, income: income)
        #expect(p.contains("Ăn uống, Di chuyển, Khác"))
        #expect(p.contains("Danh mục thu nhập: Lương"))
        #expect(p.contains("1 | chi | 35.000 đ | cf sáng"))
        #expect(p.contains("3 | thu | 20.000.000 đ | lương T10"))
        #expect(p.contains(#""results""#))
    }

    @Test func parsesFencedJSONAndCanonicalizesNames() throws {
        let reply = """
        Đây là kết quả:
        ```json
        {"results":[
          {"id":1,"category":"ăn uống","unusual":false},
          {"id":2,"category":"Di chuyen"},
          {"id":3,"category":"Lương","unusual":true,"reason":"cao hơn thường lệ"}
        ]}
        ```
        """
        let r = try Classifier.parse(reply, items: items, expense: expense, income: income)
        #expect(r.assigned == [1: "Ăn uống", 2: "Di chuyển", 3: "Lương"])
        #expect(r.unusual == [3: "cao hơn thường lệ"])
        #expect(r.suggestions.isEmpty)
    }

    @Test func neverInventsCategories() throws {
        let reply = #"{"results":[{"id":1,"category":"Cà phê"},{"id":2,"category":null,"suggest":"Taxi"},{"id":3,"category":"Ăn uống"},{"id":9,"category":"Khác"}]}"#
        let r = try Classifier.parse(reply, items: items, expense: expense, income: income)
        #expect(r.assigned.isEmpty)              // unknown name, null, wrong kind (expense name on income), unknown id
        #expect(r.suggestions == ["Cà phê", "Taxi"])
    }

    @Test func rejectsNonJSON() {
        #expect(throws: LLMError.self) { try Classifier.parse("Xin lỗi, tôi không biết", items: items, expense: expense, income: income) }
        #expect(throws: LLMError.self) { try Classifier.parse(#"{"foo":1}"#, items: items, expense: expense, income: income) }
    }
}

struct ReportNumbersTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    func day(_ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }

    func line(_ amount: Int, _ m: Int, _ d: Int, _ category: String? = nil, _ jar: String? = nil, kind: TxKind = .expense, note: String = "") -> ReportNumbers.Line {
        .init(amount: amount, kind: kind, date: day(m, d), note: note, category: category, jar: jar)
    }

    var numbers: ReportNumbers {
        ReportNumbers(lines: [
            line(10_000_000, 10, 1, "Lương", kind: .income),
            line(6_000_000, 10, 2, "Nhà ở", "Thiết yếu", note: "Tiền nhà"),
            line(500_000, 10, 5, "Ăn uống", "Thiết yếu"),
            line(1_500_000, 10, 8, "Mua sắm", "Hưởng thụ"),
            line(200_000, 10, 9),                        // uncategorized, no jar
            line(4_000_000, 9, 20, "Ăn uống", "Thiết yếu"), // last month
            line(999, 11, 1, "Ăn uống", "Thiết yếu"),     // next month
        ], jars: [("Thiết yếu", 55), ("Hưởng thụ", 10), ("Từ thiện", 5)], month: day(10, 15), calendar: cal)
    }

    @Test func totalsAndComparison() {
        let n = numbers
        #expect(n.title == "10/2026")
        #expect(n.income == 10_000_000)
        #expect(n.expense == 8_200_000)
        #expect(n.previousExpense == 4_000_000)
        #expect(n.change == 105)
    }

    @Test func byCategoryAndTop() {
        let n = numbers
        #expect(n.categories == [.init(name: "Nhà ở", total: 6_000_000), .init(name: "Mua sắm", total: 1_500_000),
                                 .init(name: "Ăn uống", total: 500_000), .init(name: ReportNumbers.uncategorized, total: 200_000)])
        #expect(n.top.map(\.amount) == [6_000_000, 1_500_000, 500_000, 200_000])
    }

    @Test func jarsAgainstIncomePercent() {
        let n = numbers
        #expect(n.jars == [.init(name: "Thiết yếu", percent: 55, spent: 6_500_000, target: 5_500_000),
                           .init(name: "Hưởng thụ", percent: 10, spent: 1_500_000, target: 1_000_000),
                           .init(name: "Từ thiện", percent: 5, spent: 0, target: 500_000)])
        #expect(n.unjarred == 200_000)
        let md = n.markdown
        #expect(md.contains("- Thiết yếu (55%): 6.500.000 đ / mục tiêu 5.500.000 đ ⚠️ vượt"))
        #expect(md.contains("- Từ thiện (5%): 0 đ / mục tiêu 500.000 đ\n"))
        #expect(md.contains("- Chưa gán lọ: 200.000 đ"))
        #expect(md.contains("tăng 105%"))
        #expect(md.contains("Tiền nhà: 6.000.000 đ"))
    }

    @Test func noIncomeMeansNoTarget() {
        let n = ReportNumbers(lines: [line(100, 10, 3, "Ăn uống", "Thiết yếu")], jars: [("Thiết yếu", 55)], month: day(10, 1), calendar: cal)
        #expect(n.jars.first?.target == nil)
        #expect(n.change == nil)
        #expect(!n.markdown.contains("So với tháng trước"))
    }
}
