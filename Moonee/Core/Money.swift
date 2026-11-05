import Foundation

/// An amount in minor units (VND has none, USD cents, KWD fils) plus an ISO 4217 code.
/// Every stored amount in Moonee is an `Int` of minor units next to a `currencyCode`.
struct Money: Hashable, Codable {
    var minor: Int
    var currency: String

    init(_ minor: Int, _ currency: String = Money.defaultCurrency) {
        self.minor = minor
        self.currency = currency
    }

    /// From a typed/decimal amount: `Money(major: 12.5, "USD")` → 1250 minor.
    init(major: Decimal, _ currency: String = Money.defaultCurrency) {
        var scaled = major * Money.scale(currency), rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        self.init(NSDecimalNumber(decimal: rounded).intValue, currency)
    }

    var major: Decimal { Decimal(minor) / Money.scale(currency) }

    func formatted(locale: Locale = .autoupdatingCurrent) -> String {
        major.formatted(.currency(code: currency).locale(locale))
    }

    // MARK: - Default currency

    /// UserDefaults key for the user's currency override (Settings, spec §6.1). Unset = device region.
    static let currencyKey = "money.currency"

    static var defaultCurrency: String {
        UserDefaults.standard.string(forKey: currencyKey) ?? Locale.current.currency?.identifier ?? "USD"
    }

    static func fractionDigits(_ currency: String) -> Int {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        return f.maximumFractionDigits
    }

    private static func scale(_ currency: String) -> Decimal {
        pow(10, fractionDigits(currency))
    }
}
