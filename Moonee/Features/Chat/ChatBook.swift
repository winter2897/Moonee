import Foundation
import SwiftData
import SwiftUI

/// One line of the Moonee chat, kept on device (and in iCloud once sync is on).
@Model final class ChatMessage {
    var date: Date = Date.now
    var fromUser: Bool = false
    /// Markdown; Moonee bolds amounts.
    var text: String = ""
    /// Set by Undo: the card stays, struck through.
    var undone: Bool = false
    /// JSON `[ChatCardLine]`: what the card showed when it was undone, since its txns are deleted.
    var undoneLines: Data?
    @Relationship(deleteRule: .nullify, inverse: \Txn.chatMessage) var txns: [Txn]? = []

    init(fromUser: Bool, text: String, date: Date = .now) {
        self.fromUser = fromUser
        self.text = text
        self.date = date
    }

    /// In the order they were saved (SwiftData relationships are unordered).
    var savedTxns: [Txn] { (txns ?? []).sorted { $0.createdAt < $1.createdAt } }
}

/// What a transaction card row shows; a value so an undone card can still be drawn.
struct ChatCardLine: Codable, Equatable {
    var title: String
    var symbol: String
    var colorHex: Int
    var category: String
    var jar: String?
    var date: Date
    var amount: Int
    var currency: String
    var income: Bool

    init(_ t: Txn) {
        let label = t.category?.name ?? t.kind.title
        title = t.note.isEmpty ? label : t.note.prefix(1).uppercased() + t.note.dropFirst()
        symbol = t.category?.icon ?? Self.symbol(t.kind)
        colorHex = t.category?.colorHex ?? 0x22C55E
        switch t.kind {
        case .expense: (category, jar) = (label, t.jar?.name)
        case .transfer: (category, jar) = (label, [t.wallet?.name, t.toWallet?.name].compactMap { $0 }.joined(separator: " → "))
        case .jarTransfer: (category, jar) = (label, [t.jar?.name, t.toJar?.name].compactMap { $0 }.joined(separator: " → "))
        case .lend, .borrow, .repay: (category, jar) = (label, t.debt?.person)
        case .income: (category, jar) = (label, nil)
        }
        if jar?.isEmpty == true { jar = nil }
        date = t.date
        amount = t.amount
        currency = t.currencyCode
        income = t.kind == .income || t.kind == .borrow
    }

    private static func symbol(_ kind: TxKind) -> String {
        switch kind {
        case .expense: "tag.fill"
        case .income: "plus.circle.fill"
        case .transfer: "arrow.left.arrow.right"
        case .jarTransfer: "arrow.triangle.swap"
        case .lend: "arrow.up.right.circle.fill"
        case .borrow: "arrow.down.left.circle.fill"
        case .repay: "checkmark.circle.fill"
        }
    }

    func item(id: UUID = UUID(), calendar: Calendar = .current) -> ChatTransactionCard.Item {
        let when = calendar.isDateInToday(date) ? String(localized: "Today", table: "Chat")
            : calendar.isDateInYesterday(date) ? String(localized: "Yesterday", table: "Chat")
            : date.formatted(.dateTime.day().month())
        return .init(id: id, title: title, symbol: symbol, color: Color(hex: colorHex), category: category, jar: jar,
                     when: when, amount: amount, currency: currency, income: income)
    }
}

/// The chat's writes to the books (spec §3.2): save right away, undo, learn from edits.
@MainActor enum ChatBook {
    /// Saves every parsed transaction that has an amount and allocates it to jars once. Amountless ones are skipped:
    /// the chat asks for the amount first instead of guessing.
    static func save(_ parsed: [ParsedTxn], source: TxSource, rawInput: String, in context: ModelContext) -> [Txn] {
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let wallets = (try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        var debts = (try? context.fetch(FetchDescriptor<Debt>())) ?? []
        func wallet(_ name: String?) -> Wallet? { name.flatMap { n in wallets.first { $0.name == n } } }
        func jar(_ key: String?) -> Jar? { key.flatMap { k in jars.first { $0.parserKey == k } } }
        func debt(_ person: String?, _ kind: TxKind, _ currency: String) -> Debt? {
            guard let person else { return nil }
            let direction: DebtDirection? = kind == .lend ? .lent : kind == .borrow ? .borrowed : nil // repay settles either
            if let d = debts.first(where: { $0.person.localizedCaseInsensitiveCompare(person) == .orderedSame && (direction == nil || $0.direction == direction) }) {
                return d
            }
            guard let direction else { return nil }
            let d = Debt(person: person, direction: direction, currencyCode: currency)
            context.insert(d)
            debts.append(d)
            return d
        }

        var out: [Txn] = []
        for p in parsed {
            guard let amount = p.amount, amount > 0 else { continue }
            let kind = TxKind(rawValue: p.kind.rawValue) ?? .expense
            let t = Txn(amount: amount, kind: kind, currencyCode: p.currency, date: p.date, note: p.note, source: source, rawInput: rawInput,
                        category: p.categoryKey.flatMap { k in categories.first { $0.parserKey == k } },
                        wallet: wallet(p.wallet) ?? wallets.first)
            context.insert(t)
            switch kind {
            case .transfer: t.toWallet = wallet(p.toWallet)
            case .jarTransfer: (t.jar, t.toJar) = (jar(p.jar), jar(p.toJar))
            case .lend, .borrow, .repay: t.debt = debt(p.person, kind, p.currency)
            case .expense, .income: break
            }
            t.allocate(jars: jars, in: context)
            out.append(t)
        }
        return out
    }

    /// Removes the message's transactions from the books; the card stays, struck through.
    static func undo(_ message: ChatMessage, in context: ModelContext) {
        let txns = message.savedTxns
        message.undoneLines = try? JSONEncoder().encode(txns.map(ChatCardLine.init))
        message.undone = true
        txns.forEach(context.delete)
    }

    static func undoneLines(_ message: ChatMessage) -> [ChatCardLine] {
        message.undoneLines.flatMap { try? JSONDecoder().decode([ChatCardLine].self, from: $0) } ?? []
    }

    /// The user corrected a category: re-pin this expense's jar and remember note → category for the next parse (spec §3.2).
    // ponytail: the pattern is the whole note ("highlands"); a note with extra words only matches itself.
    static func setCategory(_ category: Category?, of txn: Txn, in context: ModelContext) {
        guard txn.category != category else { return }
        txn.category = category
        if txn.kind == .expense { txn.jar = category?.jar }
        let pattern = txn.note.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let category, !pattern.isEmpty else { return }
        let rules = (try? context.fetch(FetchDescriptor<MerchantRule>(predicate: #Predicate { $0.pattern == pattern }))) ?? []
        if let rule = rules.first {
            rule.category = category
            rule.updatedAt = .now
        } else {
            context.insert(MerchantRule(pattern: pattern, category: category))
        }
    }

    /// An income's amount changed: split it again by the current percents.
    static func resplit(_ txn: Txn, in context: ModelContext) {
        guard txn.kind == .income else { return }
        (txn.splits ?? []).forEach(context.delete)
        txn.splits = []
        txn.allocate(jars: (try? context.fetch(FetchDescriptor<Jar>())) ?? [], in: context)
    }

    // MARK: Receipts

    /// A receipt's OCR lines → one expense: the last "total" line's amount (else the biggest amount), the first text line as merchant.
    // ponytail: rule-based; hand the lines to a vision/LLM model when one is configured (spec §9.3).
    nonisolated static func receipt(_ lines: [String], context: ParserContext) -> ParsedTxn {
        let totalWords = ["tổng", "total", "thanh toán", "cộng", "phải trả", "amount due"]
        let amounts = lines.compactMap { l in QuickParser.amount(in: l, context: context).map { (line: l.lowercased(), money: $0) } }
        let total = amounts.last { a in totalWords.contains { a.line.contains($0) } } ?? amounts.max { $0.money.amount < $1.money.amount }
        let merchant = lines.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && QuickParser.amount(in: $0, context: context) == nil } ?? ""
        let lower = merchant.lowercased()
        var t = ParsedTxn(amount: total?.money.amount, currency: total?.money.currency ?? context.currency, kind: .expense,
                          categoryKey: context.merchantRules.first { lower.contains($0.key) }?.value
                              ?? QuickParser.hints(in: merchant, context: context).categoryKey,
                          date: context.now, note: merchant)
        t.missing = ParsedTxn.missing(of: t)
        return t
    }

    // MARK: Plain numbers

    /// When no model can answer, the tools' numbers as a short Moonee message. Nil = nothing usable.
    nonisolated static func factsText(_ facts: [Assistant.ToolResult]) -> String? {
        for f in facts {
            guard let json = try? JSONSerialization.jsonObject(with: Data(f.json.utf8)) else { continue }
            let o = json as? [String: Any] ?? [:]
            func s(_ k: String, _ d: [String: Any]? = nil) -> String { ((d ?? o)[k] as? String) ?? "" }
            switch f.tool {
            case "spendingSummary":
                var text = String(localized: "You spent **\(s("spent"))** \(periodName(s("period"))).", table: "Chat")
                if let change = o["change"] as? String { text += " " + String(localized: "That's \(change) vs the period before.", table: "Chat") }
                let top = (o["topCategories"] as? [[String: Any]] ?? []).map { "• \(s("name", $0)): **\(s("spent", $0))** (\(s("share", $0)))" }
                return ([text] + top).joined(separator: "\n")
            case "jarBalances":
                let rows = (json as? [[String: Any]] ?? []).map { j in
                    "• \(s("name", j)): **\(s("balance", j))**" + (s("status", j) == "ok" ? "" : " ⚠️")
                }
                guard !rows.isEmpty else { continue }
                return ([String(localized: "Here's what's in your jars right now:", table: "Chat")] + rows).joined(separator: "\n")
            case "monthClose":
                return String(localized: "This month: income **\(s("income"))**, spent **\(s("spent"))**, saved **\(s("saved"))**.", table: "Chat")
            case "splitIncome":
                let rows = (o["jars"] as? [[String: Any]] ?? []).map { "• \(s("name", $0)) (\(s("percent", $0))): **\(s("amount", $0))**" }
                return ([String(localized: "Here's how **\(s("amount"))** splits into your jars:", table: "Chat")] + rows).joined(separator: "\n")
            case "savingsPlan":
                return String(localized: "Put aside **\(s("perWeek"))** a week (**\(s("perMonth"))** a month) to reach \(s("target")) by \(s("deadline")).", table: "Chat")
            default: continue
            }
        }
        return nil
    }

    nonisolated private static func periodName(_ raw: String) -> String {
        switch LedgerPeriod(rawValue: raw) ?? .thisMonth {
        case .today: String(localized: "today", table: "Chat")
        case .thisWeek: String(localized: "this week", table: "Chat")
        case .lastWeek: String(localized: "last week", table: "Chat")
        case .thisMonth: String(localized: "this month", table: "Chat")
        case .lastMonth: String(localized: "last month", table: "Chat")
        case .thisYear: String(localized: "this year", table: "Chat")
        case .lastYear: String(localized: "last year", table: "Chat")
        }
    }
}
