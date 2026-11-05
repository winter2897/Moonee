import Foundation
@testable import Moonee

/// In-memory books for tool tests.
struct InMemoryLedger: LedgerReading {
    var currency = "VND"
    var jarList: [LedgerJar]
    var txns: [LedgerTxn]

    func jars() async throws -> [LedgerJar] { jarList }
    func transactions(in i: DateInterval) async throws -> [LedgerTxn] { txns.filter { $0.date >= i.start && $0.date < i.end } }
}

/// A model that replays scripted replies and records requests. Uses the protocol's default (JSON) extraction.
final class ScriptedLLM: LLM, @unchecked Sendable {
    let isSmall: Bool
    var replies: [String]
    var requests: [LLMRequest] = []

    init(small: Bool = false, replies: [String]) {
        isSmall = small
        self.replies = replies
    }

    func respond(_ r: LLMRequest) async throws -> String {
        requests.append(r)
        guard !replies.isEmpty else { throw LLMError("offline") }
        return replies.removeFirst()
    }
}

/// Replays provider JSON replies and records what the client sent.
final class StubTransport: @unchecked Sendable {
    var replies: [(status: Int, body: [String: Any])]
    var requests: [URLRequest] = []

    init(_ replies: [[String: Any]]) { self.replies = replies.map { (200, $0) } }
    init(status: Int, body: [String: Any]) { replies = [(status, body)] }

    var bodies: [[String: Any]] { requests.map { (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data())) as? [String: Any] ?? [:] } }

    var send: HTTPTransport {
        { req in
            self.requests.append(req)
            let r = self.replies.removeFirst()
            return (try JSONSerialization.data(withJSONObject: r.body),
                    HTTPURLResponse(url: req.url!, statusCode: r.status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// October + November 2026 of a user with the 6 default jars. "Now" is Friday 20 Nov 2026.
enum Books {
    static let cal = QuickParserTests.cal
    static let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))!
    static func d(_ month: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))! }

    static let salarySplit = ["jar.essentials": 5_500_000, "jar.investment": 1_000_000, "jar.savings": 1_000_000,
                              "jar.education": 1_000_000, "jar.play": 1_000_000, "jar.giving": 500_000]

    static let ledger = InMemoryLedger(
        jarList: [
            .init(key: "jar.essentials", name: "Thiết yếu", percent: 55, balance: 5_300_000),
            .init(key: "jar.investment", name: "Đầu tư", percent: 10, balance: 2_000_000),
            .init(key: "jar.savings", name: "Tiết kiệm", percent: 10, balance: 1_700_000),
            .init(key: "jar.education", name: "Phát triển bản thân", percent: 10, balance: 2_000_000),
            .init(key: "jar.play", name: "Hưởng thụ", percent: 10, balance: 200_000),
            .init(key: "jar.giving", name: "Từ thiện", percent: 5, balance: 1_000_000),
        ],
        txns: [
            .init(date: d(10, 1), amount: 10_000_000, kind: .income, categoryKey: "category.salary", categoryName: "Lương", splits: salarySplit),
            .init(date: d(10, 5), amount: 3_000_000, kind: .expense, categoryKey: "category.food", categoryName: "Ăn uống", jarKey: "jar.essentials"),
            .init(date: d(10, 10), amount: 1_200_000, kind: .expense, categoryKey: "category.entertainment", categoryName: "Giải trí", jarKey: "jar.play"),
            .init(date: d(10, 12), amount: 200_000, kind: .expense, jarKey: "jar.essentials", note: "???"),
            .init(date: d(11, 1), amount: 10_000_000, kind: .income, categoryKey: "category.salary", categoryName: "Lương", splits: salarySplit),
            .init(date: d(11, 3), amount: 2_000_000, kind: .expense, categoryKey: "category.food", categoryName: "Ăn uống", jarKey: "jar.essentials"),
            .init(date: d(11, 15), amount: 500_000, kind: .expense, categoryKey: "category.food", categoryName: "Ăn uống", jarKey: "jar.essentials", note: "Lẩu"),
            .init(date: d(11, 16), amount: 900_000, kind: .expense, categoryKey: "category.shopping", categoryName: "Mua sắm", jarKey: "jar.play"),
            .init(date: d(11, 18), amount: 1_000_000, kind: .lend, note: "Cho Nam mượn", person: "Nam"),
            .init(date: d(11, 19), amount: 300_000, kind: .jarTransfer, jarKey: "jar.savings", toJarKey: "jar.play"),
        ])

    static var tools: MooneeTools {
        MooneeTools(ledger: ledger, now: { now }, calendar: cal, locale: Locale(identifier: "en_US"))
    }

    static var context: ParserContext {
        var c = QuickParserTests.context
        c.now = now
        return c
    }
}

extension MooneeTools {
    /// Runs a tool by name with JSON args, returning the decoded JSON object (or array) for assertions.
    func json(_ name: String, _ args: String = "{}") async -> Any? {
        let out = await all.call(name, arguments: Data(args.utf8))
        return try? JSONSerialization.jsonObject(with: Data(out.utf8))
    }
}
