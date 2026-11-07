import Foundation

/// Language-independent keys for the default jars and categories (spec §10.3: store keys, show translated names).
enum DefaultKeys {
    static let jars = ["jar.essentials", "jar.investing", "jar.savings", "jar.growth", "jar.play", "jar.giving"]
    static let expenseCategories = [
        "category.food", "category.transport", "category.housing", "category.health", "category.shopping",
        "category.entertainment", "category.education", "category.charity", "category.other",
    ]
    static let incomeCategories = ["category.salary", "category.bonus", "category.otherIncome"]
    static var categories: [String] { expenseCategories + incomeCategories }
}

/// The rule parser's dictionary for one language (spec §10.3). Each language lives in
/// `Moonee/Resources/Locales/<code>/` next to its prompt and skill files. All words are written
/// lowercase with diacritics; input typed without diacritics still matches.
/// To add a language: copy `Locales/en`, translate, append it to `Lexicon.all`.
struct Lexicon: Sendable {
    var language: String
    /// Slang after (or glued to) a number: "k" → 1_000, "củ" → 1_000_000. Currency-agnostic: "45k" is 45,000 of the current currency.
    var multipliers: [String: Decimal] = [:]
    /// Words or symbols naming a currency: "đ" → "VND", "$" → "USD". Override the default currency.
    var currencies: [String: String] = [:]
    /// Relative day phrases: "hôm qua" → -1.
    var dayOffsets: [String: Int] = [:]
    /// Weekday phrases → Calendar weekday (1 = Sunday). The latest one on or before today.
    var weekdays: [String: Int] = [:]
    /// After a weekday: "of last week" ("tuần trước").
    var lastWeekSuffixes: [String] = []
    /// Before a weekday: the latest one strictly before today ("last").
    var lastPrefixes: [String] = []
    /// Before a day number: day of this month ("ngày 5").
    var dayOfMonthPrefixes: [String] = []
    /// Kind cues, checked in order; the first match wins. Words split by spaces, `a|b` = either,
    /// `*` = the person (or a gap of up to 3 words). A pattern without `*` is a plain phrase.
    var kindPatterns: [(EntryKind, String)] = []
    /// Words that are never a person: "tiền", "money".
    var notPerson: [String] = []
    /// Titles that belong to the name after them: "anh" Tuấn, "uncle" Bob.
    var honorifics: [String] = []
    /// Before a wallet or jar: it is the destination ("sang", "to").
    var toMarkers: [String] = []
    /// Words that also split one message into several transactions (besides , ; and new lines).
    var separators: [String] = []
    var categories: [(key: String, words: [String])] = []
    /// Bill names → category, checked before `categories` for a bill ("nước" is the water bill there, not a drink).
    var bills: [(key: String, words: [String])] = []
    var jars: [(key: String, words: [String])] = []
    /// A word meaning "jar" ("lọ"): a transfer that names one is a jar transfer.
    var jarWords: [String] = []
    var questionCues: [String] = []
    /// Skill id → phrases that ask for it ("chốt sổ" → close-management).
    var skillCues: [(skill: String, words: [String])] = []
    /// Period phrases in questions → `LedgerPeriod` raw value ("tháng này" → "thisMonth").
    var periods: [String: String] = [:]
    /// Receipt lines that hold the total ("tổng cộng", "total"). Longest first.
    var receiptTotals: [String] = []
    /// Spelled-out numbers for languages that write them as one run ("ห้าสิบ" = 50): digits 1–9, the tens/hundreds…
    /// units, and odd ones (Lao "ຊາວ" = 20). The tokeniser turns a run of these into digits.
    var numberWords: [String: Int] = [:]

    static let all: [Lexicon] = [.vi, .en, .th, .lo]
}

// MARK: - Matching helpers shared by the parser and the skill router

/// One word of input, pre-normalised for matching.
struct Token {
    let original: String
    /// Lowercased, NFC, edge punctuation trimmed.
    let lower: String
    /// `lower` without diacritics ("đ" → "d").
    let folded: String
    /// Written straight after the previous word, no space: Thai and Lao don't put spaces between words.
    var glued = false
    var hasDiacritics: Bool { lower != folded }

    init(_ word: String, glued: Bool = false) {
        original = word.trimmingCharacters(in: Token.edge)
        lower = original.lowercased().precomposedStringWithCanonicalMapping
        folded = Token.fold(lower)
        self.glued = glued
    }

    /// A spelled-out number: shows as written, matches as digits.
    private init(number: Int, original: String, glued: Bool) {
        self.original = original
        (lower, folded, self.glued) = (String(number), String(number), glued)
    }

    /// A lexicon word matches with its diacritics, or folded when the user typed none ("hom qua").
    func matches(_ word: String) -> Bool {
        lower == word || (!hasDiacritics && folded == Token.fold(word))
    }

    static let edge = CharacterSet(charactersIn: ".,!?;:\"'()[]{}…")

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).replacingOccurrences(of: "đ", with: "d")
    }

    static func split(_ text: String) -> [Token] {
        spellNumbers(words(text).map { Token($0.text, glued: $0.glued) }.filter { !$0.original.isEmpty })
    }

    /// Text again from some tokens: a space only where the user typed one.
    static func join(_ tokens: some Sequence<Token>, _ text: KeyPath<Token, String> = \.original) -> String {
        tokens.enumerated().map { ($0.offset > 0 && !$0.element.glued ? " " : "") + $0.element[keyPath: text] }.joined()
    }

    /// Words split by spaces; a Thai or Lao run is cut into words by the system's dictionary word breaker (ICU),
    /// and digits glued to it come apart ("กาแฟ50บาท" → กาแฟ · 50 · บาท). Thai and Lao digits become 0–9.
    static func words(_ text: String) -> [(text: String, glued: Bool)] {
        text.split(whereSeparator: \.isWhitespace).flatMap { chunk -> [(text: String, glued: Bool)] in
            let word = String(String.UnicodeScalarView(chunk.unicodeScalars.map(asciiDigit)))
            guard word.unicodeScalars.contains(where: isSEAsianLetter) else { return [(word, false)] }
            var out: [(text: String, glued: Bool)] = []
            var start = word.startIndex
            while start < word.endIndex {
                let letters = isSEAsianLetter(word.unicodeScalars[start])
                let end = word[start...].firstIndex { isSEAsianLetter($0.unicodeScalars.first!) != letters } ?? word.endIndex
                let run = String(word[start..<end])
                if letters {
                    run.enumerateSubstrings(in: run.startIndex..., options: .byWords) { w, _, _, _ in
                        if let w { out.append((w, !out.isEmpty)) }
                    }
                } else {
                    out.append((run, !out.isEmpty))
                }
                start = end
            }
            return out
        }
    }

    private static func isSEAsianLetter(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x0E01...0x0E3A, 0x0E40...0x0E4E, 0x0E81...0x0ECE, 0x0EDC...0x0EDF: true // Thai, Lao; not ฿ or digits
        default: false
        }
    }

    private static func asciiDigit(_ c: Unicode.Scalar) -> Unicode.Scalar {
        switch c.value {
        case 0x0E50...0x0E59: Unicode.Scalar(c.value - 0x0E50 + 0x30)! // ๐–๙
        case 0x0ED0...0x0ED9: Unicode.Scalar(c.value - 0x0ED0 + 0x30)! // ໐–໙
        default: c
        }
    }

    // MARK: Spelled-out numbers (Thai, Lao)

    private static let numberWords: [String: Int] = Lexicon.all.reduce(into: [:]) { $0.merge($1.numberWords) { a, _ in a } }
    private static let longestNumberWord = numberWords.keys.map(\.count).max() ?? 0
    private static let units: Set<Int> = [10, 100, 1_000, 10_000, 100_000, 1_000_000]

    /// "ห้าสิบ" → [5, 10]; nil unless the whole word is number words (so "ห้าง" and "สามี" stay words).
    private static func numberParts(_ word: String) -> [Int]? {
        var parts: [Int] = [], rest = Substring(word)
        while !rest.isEmpty {
            guard let n = (1...min(longestNumberWord, rest.count)).reversed().lazy
                .compactMap({ len in numberWords[String(rest.prefix(len))].map { (len: len, v: $0) } }).first else { return nil }
            parts.append(n.v)
            rest = rest.dropFirst(n.len)
        }
        return parts.isEmpty ? nil : parts
    }

    /// [2, 1000, 5, 100] → 2500. A unit multiplies what is smaller than it, so Lao "ຫ້າສິບພັນ" = 50,000; a digit after
    /// a thousands unit is the next one down, as people say it: "สองพันห้า" = 2,500, "แสนห้า" = 150,000.
    static func value(of parts: [Int]) -> Int {
        var total = 0, digit: Int?, lastUnit = 1
        for v in parts {
            if units.contains(v) {
                let small = total % v
                let n = small + (digit ?? 0)
                total += -small + (n == 0 ? 1 : n) * v
                (digit, lastUnit) = (nil, v)
            } else if v < 10 {
                digit = v
            } else {
                total += v // ຊາວ = 20
                (digit, lastUnit) = (nil, 10)
            }
        }
        return total + (digit.map { lastUnit >= 1_000 ? $0 * lastUnit / 10 : $0 } ?? 0)
    }

    /// Joins runs of number words into one numeric token. Units right after digits stay words, so "2พัน" is 2 × พัน.
    private static func spellNumbers(_ tokens: [Token]) -> [Token] {
        guard !numberWords.isEmpty, tokens.contains(where: { $0.lower.unicodeScalars.contains(where: isSEAsianLetter) }) else { return tokens }
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            var parts: [Int] = [], j = i
            while j < tokens.count, j == i || tokens[j].glued, let p = numberParts(tokens[j].lower) {
                parts += p
                j += 1
            }
            let afterDigits = out.last?.folded.last?.isNumber == true
            if parts.isEmpty || (afterDigits && parts.allSatisfy(units.contains)) {
                out.append(tokens[i])
                i += 1
            } else {
                out.append(Token(number: value(of: parts), original: join(tokens[i..<j]), glued: tokens[i].glued))
                i = j
            }
        }
        return out
    }
}

/// A lexicon phrase as words.
typealias Phrase = [String]

extension Phrase {
    /// Split like the input is, so a Thai or Lao phrase meets the same word breaks.
    init(phrase: String) { self = Token.words(phrase).map { Token($0.text).lower }.filter { !$0.isEmpty } }

    func matches(_ tokens: [Token], at i: Int) -> Bool {
        i + count <= tokens.count && indices.allSatisfy { tokens[i + $0].matches(self[$0]) }
    }

    /// First start index in `tokens` (skipping starts in `used`).
    func find(in tokens: [Token], skipping used: Set<Int> = []) -> Int? {
        tokens.indices.first { !used.contains($0) && matches(tokens, at: $0) }
    }
}

extension Array where Element == Phrase {
    init(phrases words: [String]) { self = words.map(Phrase.init(phrase:)).sorted { $0.count > $1.count } }

    func contained(in tokens: [Token]) -> Bool { contains { $0.find(in: tokens) != nil } }
}
