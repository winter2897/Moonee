import Foundation

/// What a photo, screenshot or PDF is (spec §3.1: receipts, transfer confirmations, bank app screenshots).
enum DocType: String, CaseIterable, Sendable {
    /// A store receipt, an order or an invoice: one expense, the total line.
    case receipt
    /// A bank / e-wallet payment or transfer confirmation ("Giao dịch thành công"): the big amount at the top.
    case payment
    /// A utility or service bill (electricity, water, internet).
    case bill
    /// A list of several transactions (bank history, statement).
    case statement
    /// Not about money.
    case other
}

/// A document read into transactions. Money, dates and names come from its text (rules, or a model checked against them).
struct DocRead: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case expense, income
        /// To / from a person, purpose unknown: Moonee asks (spending, a loan or a repayment).
        case sent, received
        case lend, borrow, repay
    }

    struct Item: Equatable, Sendable {
        var amount: Int
        var currency: String
        var kind: Kind
        /// The shop, the biller or the other person, as written.
        var counterparty: String?
        /// When it happened, from the document; nil = not on it.
        var date: Date?
        /// A wallet name from `ParserContext.wallets` the document names ("MoMo").
        var wallet: String?
        /// The transaction / invoice id, to skip the same screenshot twice.
        var reference: String?
        var categoryKey: String?
        /// A statement row's description.
        var note: String?
    }

    var type: DocType
    var items: [Item]
}

/// Words that tell what a document is, per language like `Lexicon` (`Locales/<lang>/DocumentWords+<lang>.swift`).
/// Lowercase with diacritics; matched without them, on word boundaries.
struct DocumentWords: Sendable {
    var language: String
    /// The payment went through: "giao dịch thành công", "successful".
    var success: [String] = []
    /// Money sent to a person, not a shop: "chuyển tiền", "người nhận".
    var transfer: [String] = []
    /// Money came in: "nhận tiền thành công", "received from".
    var incoming: [String] = []
    /// Before the amount: "số tiền", "amount".
    var amountLabels: [String] = []
    /// Before the other side's name: recipient ("tới", "to"), sender ("từ", "from"), seller ("đơn vị bán hàng").
    var toLabels: [String] = []
    var fromLabels: [String] = []
    var merchantLabels: [String] = []
    /// Before the transaction or invoice id: "mã giao dịch", "transaction id".
    var referenceLabels: [String] = []
    /// Generic headings that are never the shop's name: "hóa đơn", "receipt".
    var titles: [String] = []
    /// A utility bill: "tiền điện", "kwh".
    var bill: [String] = []
    /// A list of transactions: "sao kê", "statement".
    var statement: [String] = []
    /// A heading (with no amount) from which on the screen is app chrome, skipped to the end: "quản lý chi tiêu", "ưu đãi".
    var chromeSections: [String] = []
    /// A row that is never the transaction's amount: "số dư", "tổng chi", "tiền khách đưa", "balance".
    var chromeLines: [String] = []
    /// Generic words in wallet names ("Ví MoMo" is found as "MoMo").
    var walletWords: [String] = []

    static let all: [DocumentWords] = [.vi, .en, .th, .lo]

    static let lists: [WritableKeyPath<DocumentWords, [String]>] = [
        \.success, \.transfer, \.incoming, \.amountLabels, \.toLabels, \.fromLabels, \.merchantLabels, \.referenceLabels,
        \.titles, \.bill, \.statement, \.chromeSections, \.chromeLines, \.walletWords,
    ]
}

/// Reads OCR rows into transactions without a model (spec §9.1 fallback); a model's reading is checked against the
/// same rows. Layout matters: a confirmation screen's amount is its biggest text near the top; app chrome (MoMo's
/// "Quản lý chi tiêu" widget, ads, balances) is skipped; total words count only on receipts and bills.
enum DocumentReader {
    static func read(_ lines: [OCRLine], context: ParserContext) -> DocRead {
        let w = Words(context)
        let rows = w.content(lines).map { Row($0, context) }
        let amountRows = rows.filter { !$0.amounts.isEmpty }
        guard !amountRows.isEmpty else { return DocRead(type: .other, items: []) }

        let text = rows.map(\.line.text).joined(separator: "\n")
        let wallet = wallet(in: lines.map(\.text).joined(separator: "\n"), words: w)
        let docDate = rows.lazy.compactMap { date(in: $0.line.text, context: context) }.first

        // Several signed rows ("+5.000.000", "-32.000"): a statement, one transaction each.
        if w.has(text, \.statement) || rows.filter(\.signed).count >= 2 {
            // ponytail: statement rows carry no reference, so the same statement sent twice is logged twice.
            let items = rows.indices.filter { rows[$0].signed }.map { i -> DocRead.Item in
                // This row, then up to two plain rows above it (a description or date line; not the previous transaction).
                let near = [rows[i]] + rows[max(0, i - 2)..<i].reversed().prefix { !$0.signed }
                let note = near.lazy.map { words(of: $0.line.text, context: context) }.first { !$0.isEmpty }
                // Its date: on the row, else the nearest date header above it.
                let day = rows[...i].reversed().lazy.compactMap { date(in: $0.line.text, context: context) }.first
                return DocRead.Item(amount: rows[i].amounts[0].amount, currency: rows[i].amounts[0].currency,
                                    kind: rows[i].plus ? .income : .expense, date: day ?? docDate, wallet: wallet,
                                    categoryKey: note.flatMap { QuickParser.hints(in: $0, context: context).categoryKey }, note: note)
            }
            return DocRead(type: .statement, items: items)
        }

        let total = total(rows, context)
        let isBill = w.has(text, \.bill)
        let isPayment = !isBill && (w.has(text, \.success) || w.has(text, \.transfer)) && !(total != nil && amountRows.count >= 3)
        let type: DocType = isBill ? .bill : isPayment ? .payment : .receipt

        let labelled = w.after(\.amountLabels, in: rows) { $0.amounts.first }
        guard let money = labelled ?? (type == .payment ? hero(amountRows) : total ?? hero(amountRows)) else {
            return DocRead(type: .other, items: [])
        }

        var item = DocRead.Item(amount: money.amount, currency: money.currency, kind: .expense, date: docDate, wallet: wallet,
                                reference: w.after(\.referenceLabels, in: rows, anywhere: true) { reference(in: $0.line.text) })
        let merchant = w.after(\.merchantLabels, in: rows) { w.name(in: $0.line.text) }
        if type == .payment {
            let incoming = w.has(text, \.incoming) || rows.first { $0.amounts.first?.amount == money.amount }?.plus == true
            let person = w.after(incoming ? \.fromLabels : \.toLabels, in: rows) { w.name(in: $0.line.text) }
            let toPerson = person != nil || w.has(text, \.transfer)
            item.counterparty = person ?? merchant
            item.kind = incoming ? (toPerson ? .received : .income) : (toPerson ? .sent : .expense)
        } else {
            item.counterparty = merchant ?? rows.lazy
                .filter { r in
                    r.amounts.isEmpty && !w.has(r.line.text, \.titles) && !w.has(r.line.text, \.success)
                        && date(in: r.line.text, context: context) == nil
                }
                .compactMap { w.name(in: $0.line.text) }.first
        }
        if item.kind == .expense {
            let name = (item.counterparty ?? "").lowercased()
            item.categoryKey = context.merchantRules.first { !name.isEmpty && name.contains($0.key) }?.value
                ?? QuickParser.hints(in: name, context: context).categoryKey
                ?? (type == .bill ? rows.lazy.compactMap { QuickParser.hints(in: $0.line.text, context: context).categoryKey }.first : nil)
        }
        return DocRead(type: type, items: [item])
    }

    /// The rows for a model: text with where it sits and how tall it is (`[y 21, h 45] 32.000 đ` = 21% down, 4.5% tall).
    static func layoutText(_ lines: [OCRLine], limit: Int = 120) -> String {
        lines.prefix(limit).map { l in
            l.height > 0 ? "[y \(Int((l.y * 100).rounded())), h \(Int((l.height * 1000).rounded()))] \(l.text)" : l.text
        }.joined(separator: "\n")
    }

    /// Every amount of the document, app chrome left out: what a model's amounts must be among.
    static func amounts(in lines: [OCRLine], context: ParserContext) -> [Int] {
        Words(context).content(lines).flatMap { Row($0, context).amounts.map(\.amount) }
    }

    /// "19:38 - 05/11/2026", "05-11-2026 08:15": the day and, when given, the time. Only dates within the last two years;
    /// a period ("Từ 05/10/2026 đến 04/11/2026") is not a day.
    static func date(in text: String, context: ParserContext) -> Date? {
        let days = text.matches(of: #/(?:^|\D)(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{4}|\d{2})(?!\d)/#)
        guard days.count == 1, let m = days.first else { return nil }
        var (day, month) = (Int(m.output.1)!, Int(m.output.2)!)
        if !context.dayFirst, day <= 12 { swap(&day, &month) }
        var c = DateComponents(year: Int(m.output.3)!, month: month, day: day, hour: 12, minute: 0)
        if c.year! < 100 { c.year! += 2000 }
        if let t = text.firstMatch(of: #/(?:^|\D)(\d{1,2}):(\d{2})(?!\d)/#), let h = Int(t.output.1), let mi = Int(t.output.2), h < 24, mi < 60 {
            (c.hour, c.minute) = (h, mi)
        }
        let cal = context.calendar
        guard (1...12).contains(month), (1...31).contains(day), let date = cal.date(from: c), cal.component(.day, from: date) == day,
              let earliest = cal.date(byAdding: .year, value: -2, to: context.now),
              date > earliest, date <= context.now.addingTimeInterval(86_400) else { return nil }
        return date
    }

    /// An id on a row ("#155310026979", "FT24310ABC12"): letters and digits, at least one digit.
    static func reference(in text: String) -> String? {
        text.matches(of: #/[A-Za-z0-9][A-Za-z0-9\-]{5,}/#).map { String($0.output).uppercased() }.first { $0.contains(where: \.isNumber) }
    }

    // MARK: Pieces

    /// The biggest amount (text height), the topmost of equals; without layout, the largest.
    private static func hero(_ rows: [Row]) -> (amount: Int, currency: String)? {
        if rows.contains(where: { $0.line.height > 0 }) {
            return rows.max { ($0.line.height, -$0.line.y) < ($1.line.height, -$1.line.y) }?.amounts.first
        }
        return rows.flatMap(\.amounts).max { $0.amount < $1.amount }
    }

    /// A receipt's total: the last row with a total word (lexicon `receiptTotals`, in their order), or the row under it.
    private static func total(_ rows: [Row], _ context: ParserContext) -> (amount: Int, currency: String)? {
        for key in context.lexicons.flatMap(\.receiptTotals) {
            for i in rows.indices.reversed() where Words.contains(rows[i].line.text, key) {
                if let a = rows[i].amounts.last ?? (i + 1 < rows.count ? rows[i + 1].amounts.first : nil) { return a }
            }
        }
        return nil
    }

    /// The user's wallet the document names: its whole name, or without generic words ("Ví MoMo" → "MoMo").
    private static func wallet(in text: String, words w: Words) -> String? {
        w.context.wallets.sorted { $0.count > $1.count }.first { name in
            let core = Token.split(name).map(\.original).filter { word in !w.all.walletWords.contains { Words.fold($0) == Words.fold(word) } }.joined(separator: " ")
            return Words.contains(text, name) || (core.count >= 3 && Words.contains(text, core))
        }
    }

    /// A statement row's words, without amounts, dates, times and signs.
    private static func words(of text: String, context: ParserContext) -> String {
        Token.split(text).map(\.original).filter { word in
            word.contains(where: { $0.isLetter || $0.isNumber }) && word.firstMatch(of: #/\d[\/:]\d/#) == nil
                && QuickParser.amounts(in: word, context: context).filter(\.strong).isEmpty
                && !["đ", "₫", "vnd", "vnđ"].contains(word.lowercased())
        }.joined(separator: " ")
    }

    /// One row and its money: amounts with a currency or digit grouping ("32.000 đ", "1,250,000"), never "1,0 giây".
    private struct Row {
        let line: OCRLine
        let amounts: [(amount: Int, currency: String)]
        /// "+" before an amount: money in.
        let plus: Bool
        /// "+" or "-" before an amount, as in a statement.
        let signed: Bool

        init(_ line: OCRLine, _ context: ParserContext) {
            self.line = line
            let text = line.text.replacingOccurrences(of: "−", with: "-")
            amounts = QuickParser.amounts(in: text, context: context).filter(\.strong).map { ($0.amount, $0.currency) }
            plus = !amounts.isEmpty && text.firstMatch(of: #/(^|\s)\+\s?\d/#) != nil
            signed = plus || (!amounts.isEmpty && text.firstMatch(of: #/(^|\s)-\s?\d/#) != nil)
        }
    }

    /// The word lists of the parser's languages, merged, with the matching helpers.
    private struct Words {
        let context: ParserContext
        let all: DocumentWords

        init(_ context: ParserContext) {
            self.context = context
            let langs = Set(context.lexicons.map(\.language))
            all = DocumentWords.all.filter { langs.contains($0.language) }.reduce(into: DocumentWords(language: "")) { out, d in
                for kp in DocumentWords.lists { out[keyPath: kp] += d[keyPath: kp] }
            }
        }

        static func fold(_ s: String) -> String { Token.fold(s.lowercased().precomposedStringWithCanonicalMapping) }

        /// Folded, punctuation as spaces, padded: " giao dich thanh cong ".
        static func padded(_ s: String) -> String {
            " " + String(fold(s).map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ") + " "
        }

        /// Thai and Lao write words without spaces: their phrases match anywhere.
        static func spaceless(_ s: String) -> Bool { s.unicodeScalars.contains { (0x0E00...0x0EFF).contains($0.value) } }

        static func contains(_ text: String, _ phrase: String) -> Bool {
            spaceless(phrase) ? fold(text).contains(fold(phrase)) : padded(text).contains(padded(phrase))
        }

        static func begins(_ text: String, _ phrase: String) -> Bool {
            spaceless(phrase) ? fold(text).trimmingCharacters(in: .whitespaces).hasPrefix(fold(phrase)) : padded(text).hasPrefix(padded(phrase))
        }
        func has(_ text: String, _ list: KeyPath<DocumentWords, [String]>) -> Bool { all[keyPath: list].contains { Words.contains(text, $0) } }

        private func money(_ text: String) -> Bool { !QuickParser.amounts(in: text, context: context).filter(\.strong).isEmpty }

        /// The rows that are the document: chrome rows go (with a bare amount right under one: "Số dư" / "1.000.000đ"),
        /// and from a chrome heading on, everything goes.
        func content(_ lines: [OCRLine]) -> [OCRLine] {
            var out: [OCRLine] = []
            var labelAbove = false
            for l in lines {
                let text = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let money = money(text)
                if !money, all.chromeSections.contains(where: { Words.begins(text, $0) }) { break }
                if has(text, \.chromeLines) || has(text, \.chromeSections) { labelAbove = !money; continue }
                defer { labelAbove = false }
                if labelAbove, money, Token.split(text).count <= 2 { continue }
                out.append(l)
            }
            return out
        }

        /// The text after a label at the start of a row ("Tới", "Người nhận: An", "Mã giao dịch  #1553…"), or nil.
        /// A one-word label must stand alone, end with ":" or be its own OCR piece, so "Từ ngày…" is not "from".
        static func rest(_ text: String, after labels: [String], anywhere: Bool = false) -> String? {
            let t = text.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
            let folded = Array(fold(t))
            guard folded.count == t.count else { return nil } // folding kept one letter per letter (it does for Latin scripts)
            let starts = anywhere ? folded.indices.filter { $0 == 0 || !(folded[$0 - 1].isLetter || folded[$0 - 1].isNumber) } : [0]
            for label in labels.map(fold).sorted(by: { $0.count > $1.count }) {
                for start in starts where folded[start...].starts(with: label) {
                    let after = folded[(start + label.count)...]
                    let loose = label.contains(" ") || spaceless(label) // a one-word label must stand apart; Thai/Lao have no spaces to tell
                guard after.isEmpty || after.first == ":" || after.starts(with: "  ") || (loose && after.first == " ")
                    else { continue }
                    return t.dropFirst(start + label.count).trimmingCharacters(in: CharacterSet(charactersIn: ":-–#").union(.whitespaces))
                }
            }
            return nil
        }

        /// What a labelled row says: on the row itself, else on one of the next two rows. `anywhere`: the label may be
        /// mid-row ("19:38 - 05/11/2026 - Mã giao dịch: #1553…").
        func after<T>(_ labels: KeyPath<DocumentWords, [String]>, in rows: [Row], anywhere: Bool = false, _ value: (Row) -> T?) -> T? {
            for (i, row) in rows.enumerated() {
                guard let rest = Words.rest(row.line.text, after: all[keyPath: labels], anywhere: anywhere) else { continue }
                var here = row.line
                here.text = rest
                if !rest.isEmpty, let v = value(Row(here, context)) { return v }
                for next in rows.dropFirst(i + 1).prefix(2) {
                    if let v = value(next) { return v }
                }
            }
            return nil
        }

        /// A name on a row ("Nguyễn Phước Thịnh", "HIGHLANDS COFFEE"): the first OCR piece with 3+ letters that is not
        /// money, a masked number ("****899"), initials ("PT"), a label or a status bar ("19:38  5G").
        func name(in text: String) -> String? {
            let labels = all.toLabels + all.fromLabels + all.merchantLabels + all.referenceLabels + all.amountLabels
            return text.components(separatedBy: "  ").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { piece in
                piece.filter(\.isLetter).count >= 3 && !(piece.count <= 3 && piece == piece.uppercased())
                    && !piece.contains("*") && !money(piece) && piece.filter(\.isNumber).count * 2 < piece.count
                    && Words.rest(piece, after: labels) == nil
            }.map { String($0.components(separatedBy: " - ")[0]) }
        }
    }
}
