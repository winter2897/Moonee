import Foundation

struct ParsedEntry: Equatable {
    var amount: Int
    var kind: TxKind
    var date: Date
    var note: String
    /// One of the `categories` names passed in, or nil when unsure.
    var category: String?
}

/// Turns chat-style Vietnamese ("cà phê 45k", "ăn trưa 1tr2 hôm qua", "lương 15 triệu") into a transaction.
enum QuickParser {
    static func parse(_ text: String, categories: [String] = [], now: Date = .now, calendar: Calendar = .current) -> ParsedEntry? {
        let original = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let lower = original.map { clean($0.lowercased().precomposedStringWithCanonicalMapping) }
        let folded = lower.map(fold)
        var used = Set<Int>()
        var date = now
        var income = text.trimmingCharacters(in: .whitespaces).hasPrefix("+")

        // Dates. "thứ 2" is Calendar weekday 2 (Monday); a weekday means the latest one on or before today.
        func back(to weekday: Int) -> Int { -((calendar.component(.weekday, from: now) - weekday + 7) % 7) }
        for i in folded.indices where !used.contains(i) {
            let token = folded[i], next = i + 1 < folded.count ? folded[i + 1] : ""
            var shift: Int?, span = 2
            switch (token, next) {
            case ("hom", "nay"): shift = 0
            case ("hom", "qua"), ("toi", "qua"), ("dem", "qua"): shift = -1
            case ("hom", "kia"): shift = -2
            case ("chu", "nhat"): shift = back(to: 1)
            case ("thu", _) where weekdays[next] != nil: shift = back(to: weekdays[next]!)
            case ("cn", _): (shift, span) = (back(to: 1), 1)
            case _ where token.count == 2 && token.hasPrefix("t") && weekdays[String(token.dropFirst())] != nil: // t2…t7
                (shift, span) = (back(to: weekdays[String(token.dropFirst())]!), 1)
            default: break
            }
            if let shift {
                used.formUnion(i..<i + span)
                date = calendar.date(byAdding: .day, value: shift, to: now)!
            }
        }

        // Amount: prefer one with a unit ("45k", "15 triệu", "32.000đ"), else the largest bare number.
        var candidates: [(value: Int, hasUnit: Bool, tokens: [Int])] = []
        for i in folded.indices where !used.contains(i) {
            var token = folded[i]
            if token.hasPrefix("+") || token.hasPrefix("-") { token.removeFirst() }
            guard let m = token.wholeMatch(of: amountPattern) else { continue }
            var unit = m.output[2].substring.map(String.init) ?? ""
            var tokens = [i]
            if unit.isEmpty, i + 1 < folded.count, !used.contains(i + 1), scales[folded[i + 1]] != nil {
                unit = folded[i + 1]
                tokens.append(i + 1)
            }
            let frac = m.output[3].substring.map(String.init) ?? ""
            let scale = scales[unit] ?? 1
            guard frac.isEmpty || scale > 1, var value = number(String(m.output[1].substring!), frac: frac).map({ Int(($0 * Double(scale)).rounded()) }) else { continue }
            // ponytail: bare "cà phê 45" means 45k in everyday Vietnamese; "45đ" stays literal.
            if unit.isEmpty, value < 1000 { value *= 1000 }
            if value > 0 { candidates.append((value, !unit.isEmpty, tokens)) }
        }
        guard let pick = candidates.first(where: \.hasUnit) ?? candidates.max(by: { $0.value < $1.value }) else { return nil }
        used.formUnion(pick.tokens)

        let words = " " + lower.joined(separator: " ") + " "
        if incomeWords.contains(where: { words.contains(" \($0) ") }) { income = true }

        var note = original.indices.filter { !used.contains($0) }.map { original[$0] }.joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        note = note.prefix(1).uppercased() + note.dropFirst()

        return ParsedEntry(amount: pick.value, kind: income ? .income : .expense, date: date, note: note,
                           category: guessCategory(words, categories: categories))
    }

    /// Picks the total from receipt OCR lines: a "Tổng cộng"/"Thành tiền"/"Total" line (or the line after it), else the largest grouped amount.
    static func receiptTotal(_ lines: [String]) -> Int? {
        let folded = lines.map { fold($0.lowercased().precomposedStringWithCanonicalMapping) }
        for key in totalWords {
            for (i, line) in folded.enumerated() where line.contains(key) {
                if let v = amounts(in: line, bare: true).last ?? (i + 1 < folded.count ? amounts(in: folded[i + 1], bare: true).last : nil) {
                    return v
                }
            }
        }
        return folded.flatMap { amounts(in: $0, bare: false) }.max()
    }

    // MARK: - Helpers

    private static let amountPattern = try! Regex(#"(\d+(?:[.,]\d+)*)(k|nghin|ngan|tr|trieu|cu|ty|d|vnd|dong)?(\d*)"#)
    private static let scales: [String: Int] = [
        "k": 1_000, "nghin": 1_000, "ngan": 1_000, "tr": 1_000_000, "trieu": 1_000_000, "cu": 1_000_000,
        "ty": 1_000_000_000, "d": 1, "vnd": 1, "dong": 1,
    ]
    private static let weekdays = ["2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7,
                                   "hai": 2, "ba": 3, "tu": 4, "nam": 5, "sau": 6, "bay": 7]
    // Matched with diacritics: "luong"/"nhan" without them are too ambiguous.
    private static let incomeWords = ["lương", "thưởng", "nhận", "thu nhập", "được cho", "hoàn tiền", "tiền về", "lãi", "cổ tức", "bán"]
    private static let totalWords = ["can thanh toan", "khach phai tra", "tong thanh toan", "tong cong", "tong tien", "total", "thanh tien", "thanh toan", "tong"]
    // ponytail: keyword table, the AI accountant reclassifies whatever this misses.
    private static let categoryWords: [(String, [String])] = [
        ("Lương", ["lương"]),
        ("Thưởng", ["thưởng"]),
        ("Ăn uống", ["ăn", "uống", "cà phê", "cafe", "cf", "coffee", "trà sữa", "trà", "cơm", "phở", "bún", "bánh mì", "bánh", "nhậu", "bia", "ăn trưa", "ăn sáng", "ăn tối", "highlands", "starbucks", "đi chợ"]),
        ("Di chuyển", ["grab", "taxi", "xăng", "gửi xe", "đổ xăng", "be", "xanh sm", "vé xe", "xe buýt", "bus", "vé máy bay"]),
        ("Nhà ở", ["tiền nhà", "thuê nhà", "tiền điện", "tiền nước", "internet", "wifi"]),
        ("Mua sắm", ["shopee", "lazada", "tiki", "quần", "áo", "giày", "mua sắm", "siêu thị"]),
        ("Giải trí", ["phim", "netflix", "spotify", "game", "karaoke", "du lịch"]),
        ("Sức khoẻ", ["thuốc", "khám", "bệnh viện", "gym", "nha khoa"]),
        ("Học tập", ["sách", "học phí", "khoá học", "khóa học"]),
        ("Từ thiện", ["từ thiện", "quyên góp", "ủng hộ"]),
    ]

    private static func guessCategory(_ words: String, categories: [String]) -> String? {
        if let direct = categories.first(where: { words.contains(" \($0.lowercased()) ") }) { return direct }
        return categoryWords.first { name, keys in
            categories.contains(name) && keys.contains { words.contains(" \($0) ") }
        }?.0
    }

    private static func clean(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()"))
    }

    /// "Hôm Qua" → "hom qua" so typing without diacritics still works.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).replacingOccurrences(of: "đ", with: "d")
    }

    /// "32.000" / "1,200,000" are grouping; "1.5" / "1,5" are decimals.
    private static func number(_ s: String, frac: String) -> Double? {
        let parts = s.split(whereSeparator: { $0 == "." || $0 == "," })
        let base: Double?
        if parts.dropFirst().allSatisfy({ $0.count == 3 }) {
            base = Double(parts.joined())
        } else if parts.count == 2 {
            base = Double("\(parts[0]).\(parts[1])")
        } else {
            base = nil
        }
        return base.map { frac.isEmpty ? $0 : $0 + (Double("0.\(frac)") ?? 0) }
    }

    private static let receiptPattern = try! Regex(#"\d{1,3}(?:[.,]\d{3})+|\d+"#)

    private static func amounts(in line: String, bare: Bool) -> [Int] {
        let tokens = line.split(separator: " ").filter { !$0.contains("/") && !$0.contains(":") } // skip dates, times
        let found: [String] = tokens.flatMap { t in t.matches(of: receiptPattern).map { String(t[$0.range]) } }
        let numbers: [Int] = found
            .filter { s in bare ? s.count >= 4 : (s.contains(".") || s.contains(",")) }
            .compactMap { s in Int(s.filter(\.isNumber)) }
        return numbers.filter { $0 >= 1000 }
    }
}
