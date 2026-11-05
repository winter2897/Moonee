import Foundation

/// Language-independent keys for the default jars and categories (spec §10.3: store keys, show translated names).
enum DefaultKeys {
    static let jars = ["jar.essentials", "jar.investment", "jar.savings", "jar.education", "jar.play", "jar.giving"]
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

    static let all: [Lexicon] = [.vi, .en]
}

// MARK: - Matching helpers shared by the parser and the skill router

/// One word of input, pre-normalised for matching.
struct Token {
    let original: String
    /// Lowercased, NFC, edge punctuation trimmed.
    let lower: String
    /// `lower` without diacritics ("đ" → "d").
    let folded: String
    var hasDiacritics: Bool { lower != folded }

    init(_ word: String) {
        original = word.trimmingCharacters(in: Token.edge)
        lower = original.lowercased().precomposedStringWithCanonicalMapping
        folded = Token.fold(lower)
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
        text.split(whereSeparator: \.isWhitespace).map { Token(String($0)) }.filter { !$0.original.isEmpty }
    }
}

/// A lexicon phrase as words.
typealias Phrase = [String]

extension Phrase {
    init(phrase: String) { self = phrase.lowercased().precomposedStringWithCanonicalMapping.split(separator: " ").map(String.init) }

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
