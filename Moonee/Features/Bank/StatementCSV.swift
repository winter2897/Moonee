import Foundation

/// A bank statement exported as CSV. Columns are guessed from common Vietnamese/English bank headers
/// (VCB, Techcombank, MB, ACB…: "Ngày giao dịch", "Ghi nợ"/"Ghi có" or one signed "Số tiền", "Nội dung")
/// and the user can correct the guess.
struct StatementCSV {
    struct Mapping: Equatable {
        var date: Int?
        var memo: Int?
        /// One signed column, used when set; otherwise credit − debit.
        var amount: Int?
        var debit: Int?
        var credit: Int?
        var reference: Int?
    }

    let header: [String]
    let rows: [[String]]

    init(_ text: String) {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let firstLines = text.split(whereSeparator: \.isNewline).prefix(20).joined()
        let delimiter: Character = [";", "\t", ","].max { d1, d2 in
            firstLines.filter { $0 == d1 }.count < firstLines.filter { $0 == d2 }.count
        }!
        let all = Self.parse(text, delimiter: delimiter).filter { $0.contains { !$0.isEmpty } }
        // Bank exports put a preamble (account, period…) above the real header.
        let h = all.firstIndex { let m = Self.detect($0); return m.date != nil && (m.amount != nil || m.debit != nil || m.credit != nil) } ?? 0
        header = all.indices.contains(h) ? all[h] : []
        rows = Array(all.dropFirst(h + 1))
    }

    var detected: Mapping { Self.detect(header) }

    /// Rows without a parseable date or a non-zero amount (totals, footers) are skipped.
    func drafts(_ m: Mapping) -> [BankDraft] {
        var occurrences: [String: Int] = [:]
        return rows.compactMap { r in
            func col(_ i: Int?) -> String { i.flatMap { r.indices.contains($0) ? r[$0] : nil }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            guard let date = Self.date(col(m.date)) else { return nil }
            let net = m.amount != nil
                ? Self.amount(col(m.amount)) ?? 0
                : (Self.amount(col(m.credit)).map(abs) ?? 0) - (Self.amount(col(m.debit)).map(abs) ?? 0)
            guard net != 0 else { return nil }
            let memo = col(m.memo)
            var key = col(m.reference)
            if key.isEmpty {
                // No bank reference: identify by content, numbering identical lines so two equal coffees both import.
                key = "\(col(m.date))|\(net)|\(memo)"
                occurrences[key, default: 0] += 1
                key += "#\(occurrences[key]!)"
            }
            return BankDraft(externalID: "csv:" + key, account: "", bank: "", amount: abs(net),
                             kind: net < 0 ? .expense : .income, date: date, memo: memo)
        }
    }

    // MARK: - Parsing

    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = text.makeIterator()
        var pending = chars.next()
        while let c = pending {
            pending = chars.next()
            if quoted {
                if c == "\"" {
                    if pending == "\"" { field.append("\""); pending = chars.next() } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c.isNewline { // "\r\n" is a single Character in Swift
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func detect(_ header: [String]) -> Mapping {
        var m = Mapping()
        for (i, raw) in header.enumerated() {
            let name = raw.lowercased().replacingOccurrences(of: "đ", with: "d").folding(options: .diacriticInsensitive, locale: nil)
            let words = Set(name.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            func has(_ keys: String...) -> Bool { keys.contains { $0.contains(" ") ? name.contains($0) : words.contains($0) } }
            // A bare "Nợ"/"Có" column, but not "No." (row number).
            let bare = words.subtracting(["so", "tien", "vnd"])

            if m.date == nil, has("ngay", "date") { m.date = i }
            else if m.reference == nil, has("so tham chieu", "ma giao dich", "ma gd", "so but toan", "reference", "ref", "so ct") { m.reference = i }
            else if m.debit == nil, has("ghi no", "debit", "tien ra", "withdrawal") || bare == ["no"] && !raw.contains(".") { m.debit = i }
            else if m.credit == nil, has("ghi co", "credit", "tien vao", "deposit") || bare == ["co"] { m.credit = i }
            else if m.amount == nil, has("so tien", "amount") { m.amount = i }
            else if m.memo == nil, has("noi dung", "mo ta", "dien giai", "chi tiet", "description", "details", "remark", "memo") { m.memo = i }
        }
        return m
    }

    /// "1.250.000", "1,250,000.00", "-50000", "(50,000)", "250.000 đ" → VND.
    static func amount(_ s: String) -> Int? {
        var t = s.replacingOccurrences(of: "[^0-9.,()\\-]", with: "", options: .regularExpression)
        let negative = t.hasPrefix("-") || t.hasPrefix("(")
        t = t.replacingOccurrences(of: "[.,]\\d{1,2}\\)?$", with: "", options: .regularExpression) // drop decimals; VND has none
        guard let v = Int(t.filter(\.isNumber)) else { return nil }
        return negative ? -v : v
    }

    // ponytail: day-first only, as VN banks export; add a format picker if a US-style file shows up
    private static let dateFormatters: [DateFormatter] = [
        "dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy", "dd-MM-yyyy HH:mm:ss", "dd-MM-yyyy",
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "dd/MM/yy",
    ].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        f.dateFormat = $0
        return f
    }

    static func date(_ s: String) -> Date? {
        let s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return dateFormatters.lazy.compactMap { $0.date(from: s) }.first
    }
}
