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
    /// JSON of the pages a web answer came from (`WebSource`), shown as chips under the bubble.
    var sourcesData: Data?
    /// JSON `[StoredAttachment]`: the photos (small thumbnails) and file names a user message was sent with.
    @Attribute(.externalStorage) var attachmentsData: Data?
    @Relationship(deleteRule: .nullify, inverse: \Txn.chatMessage) var txns: [Txn]? = []
    /// The conversation it belongs to (inverse declared on `ChatThread.messages`).
    var thread: ChatThread?

    init(fromUser: Bool, text: String, date: Date = .now) {
        self.fromUser = fromUser
        self.text = text
        self.date = date
    }

    var sources: [WebSource] {
        get { (sourcesData.flatMap { try? JSONDecoder().decode([StoredSource].self, from: $0) } ?? []).map(\.source) }
        set { sourcesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue.map(StoredSource.init)) }
    }

    /// `WebSource` is not Codable; this is its stored form.
    private struct StoredSource: Codable {
        var title: String, url: URL, site: String, date: Date?
        init(_ s: WebSource) { (title, url, site, date) = (s.title, s.url, s.site, s.date) }
        var source: WebSource { WebSource(title: title, url: url, site: site, date: date) }
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
        // Category · Jar first (what the owner checks); the day only when it isn't today.
        let when: String? = calendar.isDateInToday(date) ? nil
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
            if p.missing.contains(.kind) { return .kind }
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
            case .kind: ChatBook.kindChoices(p).map(\.title)
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
        case .kind:
            let choices = kindChoices(p)
            guard let kind = choices.first(where: { mentions($0.title) })?.kind
                ?? QuickParser.parse(input, context: context).first.map(\.kind).flatMap({ k in choices.first { $0.kind == k }?.kind })
            else { return false }
            p.kind = kind
        case .person:
            return false
        }
        p.missing = ParsedTxn.missing(of: p)
        return true
    }

    /// What a transfer to / from a person can be, for the quick replies: money out is spending, a loan or paying a debt
    /// back; money in is income, a loan to the user or someone paying them back.
    nonisolated static func kindChoices(_ p: ParsedTxn) -> [(kind: EntryKind, title: String)] {
        p.kind == .income || p.kind == .borrow
            ? [(.income, String(localized: "Income", table: "Chat")), (.borrow, String(localized: "I borrowed it", table: "Chat")),
               (.repay, String(localized: "Paid back to me", table: "Chat"))]
            : [(.expense, String(localized: "Spending", table: "Chat")), (.lend, String(localized: "I lent it", table: "Chat")),
               (.repay, String(localized: "Paying back a debt", table: "Chat"))]
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

        let parser = ParserContext(context)
        /// Every expense and income gets a category (and so a jar) on the card: the parser's, a guess from the words, else "Other".
        func category(_ p: ParsedTxn, _ kind: TxKind) -> Category? {
            guard kind == .expense || kind == .income else { return nil }
            let key = p.categoryKey ?? QuickParser.hints(in: p.note, context: parser).categoryKey
            let fallback = kind == .expense ? "category.other" : "category.otherIncome"
            return key.flatMap { k in categories.first { $0.parserKey == k && $0.kind == kind } } ?? categories.first { $0.key == fallback }
        }

        var out: [Txn] = []
        for p in fresh(parsed, in: context).fresh where book.unresolved(p) == nil {
            let kind = TxKind(rawValue: p.kind.rawValue) ?? .expense
            let t = Txn(amount: p.amount ?? 0, kind: kind, currencyCode: p.currency, date: p.date, note: p.note, source: source, rawInput: rawInput,
                        category: category(p, kind), wallet: book.source(p))
            t.externalID = p.reference.map(externalID)
            context.insert(t)
            switch kind {
            case .transfer: t.toWallet = book.wallet(p.toWallet)
            case .jarTransfer: (t.jar, t.toJar) = (book.jar(p.jar), book.jar(p.toJar))
            case .lend, .borrow, .repay: t.debt = debt(p.person, kind, p.currency)
            case .expense: t.jar = book.jar(p.jar) // a jar the user named; else allocate takes the category's
            case .income: break
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

    // MARK: Photos and documents

    nonisolated static func externalID(_ reference: String) -> String { "doc:" + reference }

    /// Splits off transactions whose document was already saved (same reference), also twice in one batch.
    static func fresh(_ parsed: [ParsedTxn], in context: ModelContext) -> (fresh: [ParsedTxn], duplicates: Int) {
        var seen = Set<String>()
        let fresh = parsed.filter { p in
            guard let ref = p.reference else { return true }
            let id = externalID(ref)
            guard seen.insert(id).inserted else { return false }
            return ((try? context.fetchCount(FetchDescriptor<Txn>(predicate: #Predicate { $0.externalID == id }))) ?? 0) == 0
        }
        return (fresh, parsed.count - fresh.count)
    }

    /// A photo's rows read by the rules (`DocumentReader`) → what to save, with the user's words applied.
    nonisolated static func receipt(_ lines: [OCRLine], context: ParserContext, described text: String = "") -> [ParsedTxn] {
        transactions(DocumentReader.read(lines, context: context), context: context, described: text)
    }

    /// A document's transactions to save. A transfer to / from a person waits for its kind (Moonee asks: spending, a
    /// loan or a repayment). The user's words sent with the photo ("ăn trưa với team", "cho Thịnh mượn") win for the
    /// kind, category, jar, note and day; the document's amounts always win. Several items (a statement) keep their own.
    nonisolated static func transactions(_ doc: DocRead, context: ParserContext, described text: String) -> [ParsedTxn] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let single = doc.items.count == 1 && !text.isEmpty
        let said = single ? QuickParser.parse(text, context: context).first : nil
        let hints = single ? QuickParser.hints(in: text, context: context) : (period: nil, categoryKey: nil, jarKey: nil)
        return doc.items.map { item in
            var t = ParsedTxn(amount: item.amount, currency: item.currency, kind: .expense, categoryKey: item.categoryKey, wallet: item.wallet,
                              date: item.date ?? context.now, note: item.note ?? item.counterparty ?? "")
            t.reference = item.reference
            var ask = false
            switch item.kind {
            case .expense: break
            case .income: t.kind = .income
            case .lend, .borrow, .repay: (t.kind, t.person) = (EntryKind(rawValue: item.kind.rawValue)!, item.counterparty)
            case .sent, .received: (t.kind, t.person, ask) = (item.kind == .sent ? .expense : .income, item.counterparty, true)
            }
            if single {
                let saidKind = said.map(\.kind).flatMap { [.income, .lend, .borrow, .repay].contains($0) ? $0 : nil }
                let category = said?.categoryKey ?? hints.categoryKey
                if ask, let saidKind { t.kind = saidKind; ask = false }
                if ask, category != nil { t.kind = .expense; ask = false } // "tiền cơm": it was spending
                let note = said?.note.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                t.note = note.isEmpty ? text : note
                t.categoryKey = category ?? QuickParser.hints(in: t.note, context: context).categoryKey ?? t.categoryKey
                t.jar = hints.jarKey ?? t.jar
                if let day = QuickParser.date(in: text, context: context) { t.date = day }
                if [.lend, .borrow, .repay].contains(t.kind) { t.person = said?.person ?? t.person }
            }
            t.missing = ParsedTxn.missing(of: t) + (ask ? [.kind] : [])
            return t
        }
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
                    let note: String = switch s("status", j) {
                    case "ok": ""
                    case "warning": " " + String(localized: "(running low)", table: "Chat")
                    default: " " + String(localized: "(over budget)", table: "Chat")
                    }
                    return "• \(s("name", j)): **\(s("balance", j))**" + note
                }
                guard !rows.isEmpty else { continue }
                return ([String(localized: "Here's what's in your jars right now:", table: "Chat")] + rows).joined(separator: "\n")
            case "monthBudget":
                var text = String(localized: "This month you have **\(s("left"))** left to spend of **\(s("totalBudget"))** (spent **\(s("spent"))**).", table: "Chat")
                if (o["billsDueThisMonth"] as? [Any])?.isEmpty == false {
                    text += " " + String(localized: "After the bills still due: **\(s("leftAfterBills"))**.", table: "Chat")
                }
                if let pay = (o["expectedIncome"] as? [[String: Any]])?.first {
                    text += "\n" + String(localized: "Next income: **\(s("amount", pay))** (\(s("name", pay))) on \(s("date", pay)).", table: "Chat")
                }
                return text
            case "monthClose":
                return String(localized: "This month: income **\(s("income"))**, spent **\(s("spent"))**, saved **\(s("saved"))**.", table: "Chat")
            case "splitIncome":
                let rows = (o["jars"] as? [[String: Any]] ?? []).map { "• \(s("name", $0)) (\(s("percent", $0))): **\(s("amount", $0))**" }
                return ([String(localized: "Here's how **\(s("amount"))** splits into your jars:", table: "Chat")] + rows).joined(separator: "\n")
            case "webSearch":
                guard o["configured"] as? Bool == true else {
                    return String(localized: "Web search isn't set up yet. Add a Tavily or Brave key in Account › AI assistant, or use a provider with built-in search.", table: "Chat")
                }
                if let summary = o["summary"] as? String, !summary.isEmpty { return summary }
                let hits = (o["results"] as? [[String: Any]] ?? []).prefix(3).map { "• **\(s("title", $0))**" }
                guard !hits.isEmpty else { return String(localized: "Moonee searched the web but found nothing useful.", table: "Chat") }
                return ([String(localized: "Here's what Moonee found on the web:", table: "Chat")] + hits).joined(separator: "\n")
            case "marketPrice":
                let rows = (o["prices"] as? [[String: Any]] ?? []).filter { !s("price", $0).isEmpty }
                guard !rows.isEmpty else { continue }
                var text = if let name = o["name"] as? String { // gold, exchange rates: one labelled row per price
                    (["**\(name)**"] + rows.map { "• \(s("label", $0)): **\(s("price", $0))**" }).joined(separator: "\n")
                } else {
                    "**\(s("coin").capitalized) (\(s("symbol").uppercased()))**: " + rows.map { s("price", $0) }.joined(separator: " · ")
                }
                if !s("source").isEmpty { text += "\n" + String(localized: "Source: \(s("source"))", table: "Chat") }
                return text
            case "savingsPlan":
                return String(localized: "Put aside **\(s("perWeek"))** a week (**\(s("perMonth"))** a month) to reach \(s("target")) by \(s("deadline")).", table: "Chat")
            default: continue
            }
        }
        return nil
    }

    /// The pages behind a web-search fact, for the source chips.
    nonisolated static func sources(_ facts: [Assistant.ToolResult]) -> [WebSource] {
        facts.filter { $0.tool == "webSearch" }
            .compactMap { try? JSONDecoder().decode(SearchResult.self, from: Data($0.json.utf8)) }
            .flatMap(\.results)
            .compactMap(WebSource.init)
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
