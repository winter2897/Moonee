import Foundation

/// Pure prompt building + strict JSON validation for classifying uncategorized txns.
enum Classifier {
    struct Item: Equatable {
        let id: Int
        let text: String
        let amount: Int
        let kind: TxKind
    }

    struct Result: Equatable {
        /// item id → canonical category name (validated against the list for its kind).
        var assigned: [Int: String] = [:]
        /// Names the model proposed that are not in the user's list. Never applied.
        var suggestions: [String] = []
        /// item id → reason.
        var unusual: [Int: String] = [:]
    }

    static func prompt(items: [Item], expense: [String], income: [String]) -> String {
        let lines = items.map { "\($0.id) | \($0.kind == .expense ? "chi" : "thu") | \($0.amount.vnd) | \($0.text.replacingOccurrences(of: "\n", with: " "))" }
        return """
        Danh mục chi tiêu: \(expense.joined(separator: ", "))
        Danh mục thu nhập: \(income.joined(separator: ", "))

        Giao dịch cần phân loại (id | loại | số tiền | nội dung):
        \(lines.joined(separator: "\n"))

        Chỉ trả về JSON hợp lệ, không giải thích, đúng dạng:
        {"results":[{"id":1,"category":"Tên danh mục hoặc null","suggest":null,"unusual":false,"reason":null}]}
        """
    }

    static func parse(_ reply: String, items: [Item], expense: [String], income: [String]) throws -> Result {
        struct Payload: Decodable {
            struct Row: Decodable {
                let id: Int
                let category: String?
                let suggest: String?
                let unusual: Bool?
                let reason: String?
            }
            let results: [Row]
        }
        // Models like to wrap JSON in prose or ```json fences: take the outermost object.
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(reply[start...end].utf8))
        else { throw LLMError("AI trả về JSON không hợp lệ") }

        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func canonical(_ name: String, in list: [String]) -> String? {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return list.first { $0.compare(n, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }

        var out = Result()
        for row in payload.results {
            guard let item = byID[row.id] else { continue }
            if let name = row.category, !name.isEmpty, name.lowercased() != "null" {
                if let c = canonical(name, in: item.kind == .expense ? expense : income) {
                    out.assigned[row.id] = c
                } else if canonical(name, in: expense + income) == nil {
                    out.suggestions.append(name) // wrong-kind names are just dropped
                }
            }
            if let s = row.suggest?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.lowercased() != "null" {
                out.suggestions.append(s)
            }
            if row.unusual == true { out.unusual[row.id] = row.reason ?? "" }
        }
        var seen = Set<String>()
        out.suggestions = out.suggestions.filter { seen.insert($0.lowercased()).inserted }
        return out
    }
}
