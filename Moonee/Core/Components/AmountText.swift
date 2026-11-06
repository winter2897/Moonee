import SwiftUI

extension EnvironmentValues {
    /// "Hide balances" (spec §6). Set once near the root; every `AmountText` below shows `*****`.
    @Entry var balanceHidden = false
}

/// Money from plain values: `minor` units (VND 0 digits, USD 2) + ISO 4217 code.
/// ponytail: mirrors S1's `Money.formatted()` so components don't depend on model types.
enum AmountFormat {
    static let mask = "*****"

    static func major(_ minor: Int, _ code: String) -> Decimal {
        let digits = fractionDigits(code)
        return digits == 0 ? Decimal(minor) : Decimal(minor) / pow(10, digits)
    }

    /// "1.250.000 ₫". `short`: "1,25tr" / "850k" in Vietnamese, "1.25M" / "850K" elsewhere, no symbol.
    static func string(_ minor: Int, _ code: String, short: Bool = false, plus: Bool = false, locale: Locale = .autoupdatingCurrent) -> String {
        let value = major(minor, code)
        let sign = plus && minor > 0 ? "+" : ""
        guard short else {
            return sign + value.formatted(.currency(code: code).locale(locale))
        }
        let compact = value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)).locale(locale))
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        guard locale.language.languageCode == .vietnamese else { return sign + compact }
        // ponytail: CLDR gives "1,25 Tr" / "850 N"; spec §B wants "1,25tr" / "850k".
        return sign + compact.replacingOccurrences(of: " Tr", with: "tr").replacingOccurrences(of: " N", with: "k").replacingOccurrences(of: " T", with: " tỷ")
    }

    /// What VoiceOver reads: "một triệu hai trăm năm mươi nghìn đồng việt nam", not "1.250.000".
    static func spoken(_ minor: Int, _ code: String, locale: Locale = .autoupdatingCurrent) -> String {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = locale
        let words = f.string(from: major(minor, code) as NSDecimalNumber) ?? "\(minor)"
        let name = locale.localizedString(forCurrencyCode: code)?.lowercased(with: locale) ?? code
        return "\(words) \(name)"
    }

    private static var digitsCache: [String: Int] = [:]
    static func fractionDigits(_ code: String) -> Int {
        if let d = digitsCache[code] { return d }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        digitsCache[code] = f.maximumFractionDigits
        return f.maximumFractionDigits
    }
}

/// An amount with tabular digits that shrinks instead of truncating at large Dynamic Type sizes,
/// turns into a fixed-width `*****` when balances are hidden, and is spoken in words.
struct AmountText: View {
    let minor: Int
    let currency: String
    var short = false
    /// Show "+" on positive amounts (income). Negative amounts always carry "−".
    var plus = false
    @Environment(\.balanceHidden) private var hidden
    @Environment(\.locale) private var locale

    init(_ minor: Int, currency: String, short: Bool = false, plus: Bool = false) {
        self.minor = minor
        self.currency = currency
        self.short = short
        self.plus = plus
    }

    var body: some View {
        Text(hidden ? AmountFormat.mask : AmountFormat.string(minor, currency, short: short, plus: plus, locale: locale))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityLabel(hidden ? String(localized: "Balance hidden", table: "Components") : AmountFormat.spoken(minor, currency, locale: locale))
    }
}
