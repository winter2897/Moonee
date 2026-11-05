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
    /// The user's wallets and jars, to resolve what the parser read (names, jar keys).
    struct Lookup {
        let wallets: [Wallet]
        let jars: [Jar]

        init(_ context: ModelContext) {
            wallets = (try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.order)]))) ?? []
            jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        }

        func wallet(_ name: String?) -> Wallet? { name.flatMap { n in wallets.first { $0.name == n } } }
        func jar(_ key: String?) -> Jar? { key.flatMap { k in jars.first { $0.parserKey == k } } }
        /// Money leaves this wallet; the default wallet when the message named none.
        func source(_ p: ParsedTxn) -> Wallet? { wallet(p.wallet) ?? wallets.first }

        /// What Moonee must ask before saving (spec §3.2): no amount, a transfer going nowhere, a jar move without both jars.
        // ponytail: a lend/borrow without a person still saves (no debt); ask for .person too if that matters.
        func unresolved(_ p: ParsedTxn) -> ParsedTxn.Field? {
            guard let amount = p.amount, amount > 0 else { return .amount }
            switch p.kind {
            case .transfer:
                guard let to = wallet(p.toWallet), to != source(p) else { return .toWallet }
            case .jarTransfer:
                guard let from = jar(p.jar) else { return .jar }
                guard let to = jar(p.toJar), to != from else { return .toJar }
            default: break
            }
            return nil
        }

        /// Names to offer as quick replies for `field`.
        func choices(_ field: ParsedTxn.Field, for p: ParsedTxn) -> [String] {
            switch field {
            case .toWallet: wallets.filter { $0 != source(p) }.map(\.name)
            case .jar: jars.map(\.name)
            case .toJar: jars.filter { $0 != jar(p.jar) }.map(\.name)
            case .amount, .person: []
            }
        }
    }

    /// Fills the field Moonee asked about from the user's answer ("45k", "Vietcombank", "hưởng thụ"). False = no answer in it.
    nonisolated static func fill(_ p: inout ParsedTxn, _ field: ParsedTxn.Field, from input: String, context: ParserContext) -> Bool {
        func mentions(_ name: String) -> Bool { input.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        switch field {
        case .amount:
            guard let a = QuickParser.amount(in: input, context: context) else { return false }
            (p.amount, p.currency) = (a.amount, a.currency)
        case .toWallet:
            guard let name = context.wallets.first(where: mentions) else { return false }
            p.toWallet = name
        case .jar, .toJar:
            guard let key = context.jars.first(where: { mentions($0.key) })?.value ?? QuickParser.hints(in: input, context: context).jarKey
            else { return false }
            if field == .jar { p.jar = key } else { p.toJar = key }
        case .person:
            return false
        }
        p.missing = ParsedTxn.missing(of: p)
        return true
    }

    /// Saves every parsed transaction that is complete and allocates it to jars once. The rest are skipped:
    /// the chat asks for what is missing (`Lookup.unresolved`) instead of guessing.
    static func save(_ parsed: [ParsedTxn], source: TxSource, rawInput: String, in context: ModelContext) -> [Txn] {
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let book = Lookup(context)
        var debts = (try? context.fetch(FetchDescriptor<Debt>())) ?? []
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
        for p in parsed where book.unresolved(p) == nil {
            let kind = TxKind(rawValue: p.kind.rawValue) ?? .expense
            let t = Txn(amount: p.amount ?? 0, kind: kind, currencyCode: p.currency, date: p.date, note: p.note, source: source, rawInput: rawInput,
                        category: p.categoryKey.flatMap { k in categories.first { $0.parserKey == k } },
                        wallet: book.source(p))
            context.insert(t)
            switch kind {
            case .transfer: t.toWallet = book.wallet(p.toWallet)
            case .jarTransfer: (t.jar, t.toJar) = (book.jar(p.jar), book.jar(p.toJar))
            case .lend, .borrow, .repay: t.debt = debt(p.person, kind, p.currency)
            case .expense, .income: break
            }
            t.allocate(jars: book.jars, in: context)
            out.append(t)
        }
        return out
    }

    /// Removes the message's transactions from the books; the card stays, struck through.
    /// A debt left with no transactions (made by this message's lend/borrow) goes too.
    static func undo(_ message: ChatMessage, in context: ModelContext) {
        let txns = message.savedTxns
        let ids = Set(txns.map(\.persistentModelID))
        message.undoneLines = try? JSONEncoder().encode(txns.map(ChatCardLine.init))
        message.undone = true
        let emptied = Set(txns.compactMap(\.debt)).filter { ($0.txns ?? []).allSatisfy { ids.contains($0.persistentModelID) } }
        txns.forEach(context.delete)
        emptied.forEach(context.delete)
    }

    static func undoneLines(_ message: ChatMessage) -> [ChatCardLine] {
        message.undoneLines.flatMap { try? JSONDecoder().decode([ChatCardLine].self, from: $0) } ?? []
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
