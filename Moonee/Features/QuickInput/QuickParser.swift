import Foundation

/// The 7 transaction kinds of spec §11. Raw values match the spec so the SwiftData kind maps 1:1.
enum EntryKind: String, CaseIterable, Codable, Sendable {
    case expense, income, transfer, jarTransfer, lend, borrow, repay
}

/// One transaction read from chat text. A plain value: no SwiftData.
struct ParsedTxn: Equatable, Sendable {
    /// `kind`: a transfer to / from a person read from a photo: spending, a loan or a repayment? (`DocRead.Kind.sent`).
    /// `dueDate`: asked after a lend/borrow is saved ("When will Nam pay you back?"); never blocks the save.
    enum Field: String, Codable, Sendable { case amount, person, toWallet, jar, toJar, kind, dueDate }

    /// Minor units of `currency` (VND: đồng, USD: cents). Nil = ask the user (spec §3.2), never guess.
    var amount: Int?
    /// ISO 4217 code.
    var currency: String
    var kind: EntryKind
    var categoryKey: String?
    /// Wallet names exactly as given in `ParserContext.wallets`.
    var wallet: String?
    var toWallet: String?
    /// Jar keys (jar transfers: from `jar` to `toJar`).
    var jar: String?
    var toJar: String?
    /// Lend / borrow / repay counterpart.
    var person: String?
    var date: Date
    var note: String
    /// What Moonee should ask before saving.
    var missing: [Field] = []
    /// A document's transaction id (photos): the same screenshot is not saved twice (`Txn.externalID`).
    var reference: String?
    /// Lend / borrow: when it is due back, as answered to Moonee's question (nil = no due date).
    var dueDate: Date?

    static func missing(of t: ParsedTxn) -> [Field] {
        var out: [Field] = []
        if t.amount == nil { out.append(.amount) }
        switch t.kind {
        case .lend, .borrow, .repay: if t.person == nil { out.append(.person) }
        case .transfer: if t.toWallet == nil { out.append(.toWallet) }
        case .jarTransfer:
            if t.jar == nil { out.append(.jar) }
            if t.toJar == nil { out.append(.toJar) }
        default: break
        }
        return out
    }
}

/// What the parser knows about the user. Input language is independent of the UI language: every lexicon is tried.
struct ParserContext {
    /// Default currency (spec §10.2: from the region, user-changeable). Decides what "45k" means.
    var currency = Locale.current.currency?.identifier ?? "USD"
    var now = Date.now
    var calendar = Calendar.current
    /// "5/11" is 5 November (true) or May 11.
    var dayFirst = DateFormatter.dateFormat(fromTemplate: "dM", options: 0, locale: .current)?.first == "d"
    var wallets: [String] = []
    /// User jar names (incl. custom ones) → jar key.
    var jars: [String: String] = [:]
    /// User category names → key, matched before the lexicon keywords.
    var categories: [String: String] = [:]
    /// Learned from edits (spec §3.2): merchant text → category key.
    var merchantRules: [String: String] = [:]
    var lexicons = Lexicon.all
}

/// Rule-based parser (spec §9.1 fallback): "phở 45k, cafe 29k hôm qua", "cho Nam mượn 2tr", "lent Tom $50".
/// Money and dates are always computed here, also when an LLM did the reading (see `TransactionExtractor`).
enum QuickParser {
    /// Every transaction in `text`. Pieces with no amount and no cue are dropped, so "hôm qua" alone gives [].
    /// Route questions away first (`isQuestion`).
    static func parse(_ text: String, context: ParserContext = .init()) -> [ParsedTxn] {
        let lx = Compiled(context.lexicons)
        let scan = { (tokens: [Token]) in Scan(tokens, lx: lx, context: context) }

        // , ; newline and "và" split; amountless pieces join the next one ("ăn trưa và cafe 100k").
        var segments: [[Token]] = []
        var pending: [Token] = []
        for piece in split(text, lx: lx) {
            let tokens = pending + piece
            if scan(tokens).amounts.isEmpty { pending = tokens } else { segments.append(tokens); pending = [] }
        }
        if !pending.isEmpty {
            if segments.isEmpty { segments.append(pending) } else { segments[segments.count - 1] += pending }
        }

        // "phở 45k cafe 29k" without commas: one transaction per strong amount; trailing words join the last one.
        // ponytail: amount-first lists without commas ("45k phở 29k cafe") split wrong; commas fix it.
        var chunks: [Scan] = []
        for tokens in segments {
            let s = scan(tokens)
            let strong = s.amounts.filter(\.strong)
            guard strong.count > 1 else { chunks.append(s); continue }
            var start = 0
            for (n, a) in strong.enumerated() {
                let end = n == strong.count - 1 ? tokens.count : a.range.upperBound
                chunks.append(scan(Array(tokens[start..<end])))
                start = end
            }
        }

        let sharedDate = chunks.lazy.compactMap(\.dates.first?.date).first
        return chunks.compactMap { $0.txn(defaultDate: sharedDate) }
    }

    /// The amount in a money phrase ("45k", "1tr2", "$12.50") in minor units, or nil.
    static func amount(in text: String, context: ParserContext = .init()) -> (amount: Int, currency: String)? {
        Scan(Token.split(text), lx: Compiled(context.lexicons), context: context).best.map { ($0.value, $0.currency) }
    }

    /// Every amount in a line, in order. `strong` = it has a currency, a unit or digit grouping ("32.000 đ", "45k").
    static func amounts(in text: String, context: ParserContext = .init()) -> [(amount: Int, currency: String, strong: Bool)] {
        Scan(Token.split(text), lx: Compiled(context.lexicons), context: context).amounts.map { ($0.value, $0.currency, $0.strong) }
    }

    /// The date a phrase names ("hôm qua", "last monday"), or nil.
    static func date(in text: String, context: ParserContext = .init()) -> Date? {
        Scan(Token.split(text), lx: Compiled(context.lexicons), context: context).dates.first?.date
    }

    /// What a question is about: period ("tháng này"), category ("ăn uống") and jar ("hưởng thụ").
    static func hints(in text: String, context: ParserContext = .init()) -> (period: String?, categoryKey: String?, jarKey: String?) {
        let tokens = Token.split(text), lx = Compiled(context.lexicons)
        let period = lx.periods.first { $0.0.find(in: tokens) != nil }?.1
        let jars = context.jars.map { (key: $0.value, phrases: [Phrase(phrase: $0.key)]) } + lx.jars
        let jar = jars.compactMap { j in j.phrases.lazy.compactMap { $0.find(in: tokens) }.min().map { ($0, j.key) } }.min { $0.0 < $1.0 }?.1
        return (period, parse(text, context: context).first?.categoryKey, jar)
    }

    /// A bill's category from its name (onboarding: "Điện", "Nước", "Học phí"): bill words first, then spending words.
    static func billCategory(_ name: String, context: ParserContext = .init()) -> String? {
        let tokens = Token.split(name)
        return context.lexicons.flatMap(\.bills).first { [Phrase](phrases: $0.words).contained(in: tokens) }?.key
            ?? parse(name, context: context).first?.categoryKey
    }

    static func isQuestion(_ text: String, lexicons: [Lexicon] = Lexicon.all) -> Bool {
        text.contains("?") || [Phrase](phrases: lexicons.flatMap(\.questionCues)).contained(in: Token.split(text))
    }

    /// Picks the total from receipt OCR lines: a total line (or the line after it), else the largest grouped amount.
    static func receiptTotal(_ lines: [String], lexicons: [Lexicon] = Lexicon.all) -> Int? {
        let folded = lines.map { Token.fold($0.lowercased().precomposedStringWithCanonicalMapping) }
        let keys = lexicons.flatMap(\.receiptTotals).map(Token.fold).sorted { $0.count > $1.count }
        for key in keys {
            for (i, line) in folded.enumerated() where line.contains(key) {
                if let v = receiptAmounts(in: line, bare: true).last
                    ?? (i + 1 < folded.count ? receiptAmounts(in: folded[i + 1], bare: true).last : nil) {
                    return v
                }
            }
        }
        return folded.flatMap { receiptAmounts(in: $0, bare: false) }.max()
    }

    // MARK: - Internals

    private static func split(_ text: String, lx: Compiled) -> [[Token]] {
        // A comma not followed by a digit separates ("45k, cafe"); "1,5tr" and "1,200,000" stay whole.
        text.split(separator: #/,(?!\d)|;|\n/#).flatMap { piece -> [[Token]] in
            var out: [[Token]] = [[]]
            for t in Token.split(String(piece)) {
                if lx.separators.contains(where: t.matches) { out.append([]) } else { out[out.count - 1].append(t) }
            }
            return out
        }.filter { !$0.isEmpty }
    }

    private static func receiptAmounts(in line: String, bare: Bool) -> [Int] {
        let tokens = line.split(separator: " ").filter { !$0.contains("/") && !$0.contains(":") } // skip dates, times
        // Typed steps: Xcode 26 times out type-checking this as one chain.
        let numbers: [String] = tokens.flatMap { token -> [String] in
            token.matches(of: #/\d{1,3}(?:[.,]\d{3})+|\d+/#).map { String($0.output) }
        }
        let grouped: [String] = numbers.filter { bare ? $0.count >= 4 : ($0.contains(".") || $0.contains(",")) }
        return grouped.compactMap { Int($0.filter(\.isNumber)) }.filter { $0 >= 1000 }
    }
}

/// Lexicons merged into lookup tables.
private struct Compiled {
    let multipliers: [String: Decimal]
    let currencies: [String: String]
    let dayOffsets: [(Phrase, Int)]
    let weekdays: [(Phrase, Int)]
    let periods: [(Phrase, String)]
    let lastWeek: [Phrase]
    let lastPrefixes: [Phrase]
    let dayOfMonth: [Phrase]
    let separators: [String]
    let honorifics: [String]
    let notPerson: [String]
    let toMarkers: [Phrase]
    let jarWords: [Phrase]
    let categories: [(key: String, phrases: [Phrase])]
    let jars: [(key: String, phrases: [Phrase])]
    /// Per lexicon: kind patterns are not mixed across languages.
    let patterns: [[(EntryKind, Pattern)]]

    init(_ lexicons: [Lexicon]) {
        func merged<V>(_ kp: KeyPath<Lexicon, [String: V]>) -> [String: V] {
            lexicons.reduce(into: [:]) { out, l in
                for (k, v) in l[keyPath: kp] where out[Token.fold(k)] == nil { out[Token.fold(k)] = v }
            }
        }
        func phrases<V>(_ kp: KeyPath<Lexicon, [String: V]>) -> [(Phrase, V)] {
            lexicons.flatMap { $0[keyPath: kp].map { (Phrase(phrase: $0.key), $0.value) } }.sorted { $0.0.count > $1.0.count }
        }
        multipliers = merged(\.multipliers)
        currencies = merged(\.currencies)
        dayOffsets = phrases(\.dayOffsets)
        weekdays = phrases(\.weekdays)
        periods = phrases(\.periods)
        lastWeek = [Phrase](phrases: lexicons.flatMap(\.lastWeekSuffixes))
        lastPrefixes = [Phrase](phrases: lexicons.flatMap(\.lastPrefixes))
        dayOfMonth = [Phrase](phrases: lexicons.flatMap(\.dayOfMonthPrefixes))
        separators = lexicons.flatMap(\.separators)
        honorifics = lexicons.flatMap(\.honorifics)
        notPerson = lexicons.flatMap(\.notPerson)
        toMarkers = [Phrase](phrases: lexicons.flatMap(\.toMarkers))
        jarWords = [Phrase](phrases: lexicons.flatMap(\.jarWords))
        categories = lexicons.flatMap(\.categories).map { ($0.key, [Phrase](phrases: $0.words)) }
        jars = lexicons.flatMap(\.jars).map { ($0.key, [Phrase](phrases: $0.words)) }
        patterns = lexicons.map { $0.kindPatterns.map { ($0.0, Pattern($0.1)) } }
    }
}

/// "cho * mượn|vay" → [.word(["cho"]), .star, .word(["mượn", "vay"])]. An alternative may be several words once
/// split ("เงินเดือน" → เงิน · เดือน).
private struct Pattern {
    enum Part { case word([Phrase]), star }
    /// Where a person may be: these words, the word at/after an index, or the word before an index.
    enum Capture { case words([Int]), after(Int), before(Int) }

    let parts: [Part]

    init(_ s: String) {
        parts = s.lowercased().precomposedStringWithCanonicalMapping.split(separator: " ").map {
            $0 == "*" ? .star : .word($0.split(separator: "|").map { Phrase(phrase: String($0)) })
        }
    }

    /// Nil when it does not match; else the person captures in pattern order.
    func match(_ tokens: [Token]) -> [Capture]? {
        for start in tokens.indices {
            if case .star = parts.first {
                if let caps = Pattern.run(parts.dropFirst(), tokens, start) { return [.before(start - 1)] + caps }
            } else if let caps = Pattern.run(parts[...], tokens, start) {
                return caps
            }
        }
        return nil
    }

    /// Lazy stars: a middle star takes 0–3 words.
    private static func run(_ parts: ArraySlice<Part>, _ tokens: [Token], _ i: Int) -> [Capture]? {
        guard let head = parts.first else { return [] }
        let rest = parts.dropFirst()
        switch head {
        case .word(let alts):
            for p in alts where p.matches(tokens, at: i) {
                if let caps = run(rest, tokens, i + p.count) { return caps }
            }
            return nil
        case .star where rest.isEmpty:
            return [.after(i)]
        case .star:
            for k in 0...3 where i + k <= tokens.count {
                if let caps = run(rest, tokens, i + k) { return (k > 0 ? [.words(Array(i..<i + k))] : []) + caps }
            }
            return nil
        }
    }
}

private struct Amount {
    var range: Range<Int>
    var value: Int
    var currency: String
    var strong: Bool
    var plus: Bool
}

/// Dates and amounts found in some tokens, and the transaction they make.
private struct Scan {
    let tokens: [Token]
    let lx: Compiled
    let context: ParserContext
    var used = Set<Int>()
    var dates: [(range: Range<Int>, date: Date)] = []
    var amounts: [Amount] = []

    init(_ tokens: [Token], lx: Compiled, context: ParserContext) {
        self.tokens = tokens
        self.lx = lx
        self.context = context
        findDates()
        findAmounts()
    }

    /// The amount a transaction takes: the first strong one, else the largest bare number.
    var best: Amount? { amounts.first(where: \.strong) ?? amounts.max { $0.value < $1.value } }

    // MARK: Dates

    private mutating func findDates() {
        let cal = context.calendar, now = context.now
        let today = cal.component(.weekday, from: now)
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: now)! }
        func inWeek(_ weekday: Int) -> Int { (weekday - cal.firstWeekday + 7) % 7 }

        var i = 0
        while i < tokens.count {
            var found: (len: Int, date: Date)?
            let last = lx.lastPrefixes.first { $0.matches(tokens, at: i) }
            let at = i + (last?.count ?? 0)
            if let (p, wd) = lx.weekdays.first(where: { $0.0.matches(tokens, at: at) }) {
                var len = at - i + p.count
                var back = (today - wd + 7) % 7 // latest on or before today
                if last != nil, back == 0 { back = 7 }
                if let suffix = lx.lastWeek.first(where: { $0.matches(tokens, at: i + len) }) {
                    len += suffix.count
                    back = inWeek(today) + 7 - inWeek(wd) // that weekday in the previous week
                }
                found = (len, day(-back))
            } else if let (p, offset) = lx.dayOffsets.first(where: { $0.0.matches(tokens, at: i) }) {
                found = (p.count, day(offset))
            } else if let p = lx.dayOfMonth.first(where: { $0.matches(tokens, at: i) }), i + p.count < tokens.count,
                      let d = Int(tokens[i + p.count].lower), (1...31).contains(d) {
                found = (p.count + 1, recent(day: d, month: nil, year: nil))
            } else if let m = tokens[i].lower.wholeMatch(of: #/(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?/#) {
                let (a, b) = (Int(m.output.1)!, Int(m.output.2)!)
                let (d, mo) = context.dayFirst ? (a, b) : (b, a)
                let y = m.output.3.flatMap { Int($0) }.map { $0 < 100 ? 2000 + $0 : $0 }
                if (1...31).contains(d), (1...12).contains(mo) { found = (1, recent(day: d, month: mo, year: y)) }
            }
            if let found {
                used.formUnion(i..<i + found.len)
                dates.append((i..<i + found.len, found.date))
                i += found.len
            } else {
                i += 1
            }
        }
    }

    /// That day, moved to the previous month/year when it would be in the future (people log past spending).
    private func recent(day: Int, month: Int?, year: Int?) -> Date {
        let cal = context.calendar, now = context.now
        var c = cal.dateComponents([.year, .month, .hour, .minute], from: now)
        c.day = day
        if let month { c.month = month }
        if let year { c.year = year }
        let date = cal.date(from: c) ?? now
        guard year == nil, date > now else { return date }
        return cal.date(byAdding: month == nil ? .month : .year, value: -1, to: date)!
    }

    // MARK: Amounts

    private mutating func findAmounts() {
        var i = 0
        while i < tokens.count {
            guard !used.contains(i), let a = amount(at: i) else { i += 1; continue }
            amounts.append(a)
            i = a.range.upperBound
        }
    }

    private func amount(at i: Int) -> Amount? {
        var text = tokens[i].folded
        let plus = text.hasPrefix("+")
        if plus || text.hasPrefix("-") { text.removeFirst() }
        guard let m = text.wholeMatch(of: #/([$€£¥₫฿₭])?(\d+(?:[.,]\d+)*)([^\d.,]*)(\d*)/#),
              let base = Scan.number(String(m.output.2)) else { return nil }

        var multiplier: Decimal = 1
        var currency: String? = m.output.1.flatMap { lx.currencies[String($0)] }
        let unit = String(m.output.3)
        if !unit.isEmpty {
            if let mult = lx.multipliers[unit] { multiplier = mult } else if let cur = lx.currencies[unit] { currency = cur } else { return nil }
        }
        var fraction = String(m.output.4)
        var end = i + 1
        func free(_ j: Int) -> Bool { j < tokens.count && !used.contains(j) }
        if unit.isEmpty, free(end), let mult = lx.multipliers[tokens[end].folded] { multiplier = mult; end += 1 } // "15 triệu"
        if free(end), let cur = lx.currencies[tokens[end].folded] { currency = cur; end += 1 }                   // "45k usd"
        // Spoken "1 triệu 2" = 1.2tr. Big units only, so "45k 2 tô" stays 45k.
        if fraction.isEmpty, multiplier >= 100_000, free(end), tokens[end].folded.wholeMatch(of: #/\d{1,3}/#) != nil,
           !(free(end + 1) && lx.multipliers[tokens[end + 1].folded] != nil) {
            fraction = tokens[end].folded
            end += 1
        }
        guard fraction.isEmpty || multiplier > 1 else { return nil }

        var value = (base.value + (Decimal(string: "0." + fraction) ?? 0)) * multiplier
        let code = currency ?? context.currency
        // ponytail: bare "cà phê 45" means 45k in everyday Vietnamese; "45đ" stays literal.
        if code == "VND", currency == nil, multiplier == 1, value < 1000 { value *= 1000 }
        let minor = Money(major: value, code).minor
        guard minor > 0 else { return nil }
        return Amount(range: i..<end, value: minor, currency: code,
                      strong: multiplier > 1 || currency != nil || base.grouped, plus: plus)
    }

    /// "32.000" / "1,200,000" are grouping; "1.5" / "1,5" are decimals.
    private static func number(_ s: String) -> (value: Decimal, grouped: Bool)? {
        let parts = s.split(whereSeparator: { $0 == "." || $0 == "," })
        if parts.count > 1, parts.dropFirst().allSatisfy({ $0.count == 3 }) {
            return Decimal(string: parts.joined()).map { ($0, true) }
        }
        // "1,500.00" / "1.500,50": grouped thousands with cents (Thai slips), one decimal mark at the end.
        if parts.count > 2, let mark = s.last(where: { $0 == "." || $0 == "," }), s.filter({ $0 == mark }).count == 1,
           parts.dropFirst().dropLast().allSatisfy({ $0.count == 3 }), parts.last!.count <= 2 {
            return Decimal(string: parts.dropLast().joined() + "." + parts.last!).map { ($0, true) }
        }
        if parts.count == 2 { return Decimal(string: "\(parts[0]).\(parts[1])").map { ($0, false) } }
        return parts.count == 1 ? Decimal(string: s).map { ($0, false) } : nil
    }

    // MARK: Transaction

    func txn(defaultDate: Date?) -> ParsedTxn? {
        let pick = best
        var used = self.used
        if let pick { used.formUnion(pick.range) }

        // Kind: the first matching pattern of the first lexicon that has one. Person: the first usable capture of that kind.
        var kind = EntryKind.expense, person: String?, cue = false
        for patterns in lx.patterns where !cue {
            for (k, p) in patterns {
                guard let caps = p.match(tokens), !cue || k == kind else { continue }
                (kind, cue) = (k, true)
                person = person ?? caps.lazy.compactMap { self.person($0, used: used) }.first
            }
        }
        if !cue, pick?.plus == true { (kind, cue) = (.income, true) }
        if ![.lend, .borrow, .repay].contains(kind) { person = nil }

        let wallets = mentions(context.wallets.map { ($0, [Phrase(phrase: $0)]) }, used: used)
        let jars = mentions(context.jars.map { ($0.value, [Phrase(phrase: $0.key)]) } + lx.jars, used: used)
        if kind == .transfer, wallets.all.isEmpty, !jars.all.isEmpty || lx.jarWords.contained(in: tokens) { kind = .jarTransfer }
        if kind == .expense, !cue, wallets.all.count > 1 { (kind, cue) = (.transfer, true) }

        var category: String?
        if kind == .expense || kind == .income {
            let text = Token.join(tokens, \.lower)
            category = context.merchantRules.first { text.contains($0.key.lowercased()) }?.value
                ?? mentions(context.categories.map { ($0.value, [Phrase(phrase: $0.key)]) }, used: used).all.first
                ?? lexiconCategory(kind: kind, used: used)
        }
        guard pick != nil || cue || category != nil else { return nil } // no money, no cue: not a transaction

        var txn = ParsedTxn(
            amount: pick?.value, currency: pick?.currency ?? context.currency, kind: kind, categoryKey: category,
            person: person, date: dates.first?.date ?? defaultDate ?? context.now, note: note(used: used))
        switch kind {
        case .transfer: (txn.wallet, txn.toWallet) = (wallets.from, wallets.to)
        case .jarTransfer: (txn.jar, txn.toJar) = (jars.from, jars.to)
        default: txn.wallet = wallets.all.first
        }
        txn.missing = ParsedTxn.missing(of: txn)
        return txn
    }

    /// A person name from one capture; an honorific pulls in its neighbour ("anh Tuấn").
    private func person(_ cap: Pattern.Capture, used: Set<Int>) -> String? {
        func ok(_ j: Int) -> Bool {
            tokens.indices.contains(j) && !used.contains(j) && Int(tokens[j].folded) == nil
                && !lx.notPerson.contains(where: tokens[j].matches) && !lx.separators.contains(where: tokens[j].matches)
        }
        func isTitle(_ j: Int) -> Bool { tokens.indices.contains(j) && lx.honorifics.contains(where: tokens[j].matches) }
        var picked: [Int]
        switch cap {
        case .words(let js):
            picked = js.filter(ok)
        case .after(let start):
            guard let j = (start..<max(start, tokens.count)).first(where: { !used.contains($0) }), ok(j) else { return nil }
            picked = isTitle(j) && ok(j + 1) ? [j, j + 1] : [j]
        case .before(let j):
            guard ok(j) else { return nil }
            picked = isTitle(j - 1) ? [j - 1, j] : [j]
        }
        // Thai and Lao names break into pieces ("สมชาย" → สม · ชาย): take one more glued piece.
        // ponytail: two pieces at most, and a glued verb after a name ("แม่ซื้อ") needs a `notPerson` entry.
        if case .after = cap, let j = picked.last.map({ $0 + 1 }), tokens.indices.contains(j), tokens[j].glued, ok(j) {
            picked.append(j)
        }
        if case .before = cap, let j = picked.first.map({ $0 - 1 }), tokens.indices.contains(j), tokens[j + 1].glued, ok(j), !isTitle(j + 1) {
            picked.insert(j, at: 0)
        }
        let name = Token.join(picked.map { tokens[$0] })
        return name.isEmpty ? nil : name
    }

    /// Named things in order of mention; the one after a "to" marker is the destination, else the second one.
    private func mentions(_ table: [(key: String, phrases: [Phrase])], used: Set<Int>) -> (all: [String], from: String?, to: String?) {
        var hits: [(at: Int, key: String)] = []
        var taken = used
        for (key, phrases) in table where !hits.contains(where: { $0.key == key }) {
            for p in phrases {
                guard let at = p.find(in: tokens, skipping: taken) else { continue }
                hits.append((at, key))
                taken.formUnion(at..<at + p.count)
                break
            }
        }
        hits.sort { $0.at < $1.at }
        func afterMarker(_ at: Int) -> Bool {
            (1...2).contains { back in at >= back && lx.toMarkers.contains { $0.matches(tokens, at: at - back) } }
        }
        let to = hits.first { afterMarker($0.at) }?.key ?? (hits.count > 1 ? hits[1].key : nil)
        return (hits.map(\.key), hits.first { $0.key != to }?.key, to)
    }

    /// Longest keyword wins ("tiền nước" beats "nước").
    private func lexiconCategory(kind: EntryKind, used: Set<Int>) -> String? {
        let allowed = Set(kind == .income ? DefaultKeys.incomeCategories : DefaultKeys.expenseCategories)
        var best: (len: Int, key: String)?
        for (key, phrases) in lx.categories where allowed.contains(key) {
            for p in phrases where p.count > (best?.len ?? 0) && p.find(in: tokens, skipping: used) != nil {
                best = (p.count, key)
            }
        }
        return best?.key
    }

    private func note(used: Set<Int>) -> String {
        var words = tokens.indices.filter { !used.contains($0) }.map { tokens[$0] }.drop { $0.original.hasPrefix("+") }
        if !words.isEmpty { words[words.startIndex].glued = false }
        let note = Token.join(words)
        return note.prefix(1).uppercased() + note.dropFirst()
    }
}
