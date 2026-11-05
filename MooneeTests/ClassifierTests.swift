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
        #expect(p.contains("1 | chi | \(Money(35_000).formatted()) | cf sáng"))
        #expect(p.contains("3 | thu | \(Money(20_000_000).formatted()) | lương T10"))
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
