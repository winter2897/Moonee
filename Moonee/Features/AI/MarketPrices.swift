import Foundation

/// The `marketPrice` tool's keyless sources, for the questions people ask most (spec §3.3), so every AI mode
/// (local, no search key) gets real numbers:
/// - crypto: CoinGecko public `simple/price`;
/// - gold: PNJ's public price feed (SJC bars and PNJ 999.9 rings, as PNJ sells and buys them; sjc.com.vn sits behind a
///   bot check);
/// - exchange rates: Vietcombank's public rate table (VND per unit).
/// Every reply is cached 5 minutes (Vietcombank asks for no more than one request per 5 minutes) with an 8 s timeout.
/// Anything else (stocks, interest rates, fuel, news) goes through `webSearch`.
/// What the user sees never names these providers (owner's call): quotes say "reference prices on the internet"
/// (`Quote.source`) and the gold products get generic names (`goldNames`).
struct MarketPrices: Sendable {
    var send: HTTPTransport = HTTP.live
    var cache = QuoteCache.shared
    var now: @Sendable () -> Date = { .now }

    static let timeout: TimeInterval = 8

    /// Ticker → CoinGecko id. Names ("bitcoin") and CoinGecko ids are accepted too.
    static let coins: [String: String] = [
        "btc": "bitcoin", "eth": "ethereum", "usdt": "tether", "usdc": "usd-coin", "bnb": "binancecoin", "sol": "solana",
        "xrp": "ripple", "ada": "cardano", "doge": "dogecoin", "ton": "the-open-network", "trx": "tron", "dot": "polkadot",
        "ltc": "litecoin", "link": "chainlink", "avax": "avalanche-2", "shib": "shiba-inu",
    ]

    /// Gold symbol → PNJ product codes.
    static let gold: [String: [String]] = ["SJC": ["SJC"], "PNJ": ["N24K"], "GOLD": ["SJC", "N24K"]]

    /// PNJ product code → a name without a brand.
    static var goldNames: [String: String] {
        ["SJC": String(localized: "Gold bars 999.9", table: "AI"), "N24K": String(localized: "Plain gold rings 999.9", table: "AI")]
    }

    /// Where every quote says it comes from.
    static var sourceName: String { String(localized: "Reference prices on the internet", table: "AI") }

    /// Currencies in Vietcombank's table.
    static let fx: Set<String> = ["USD", "EUR", "GBP", "JPY", "AUD", "CAD", "CHF", "CNY", "DKK", "HKD", "INR", "KRW", "KWD",
                                  "MYR", "NOK", "RUB", "SAR", "SEK", "SGD", "THB"]

    static func coinID(_ symbol: String) -> String? {
        let s = symbol.lowercased().trimmingCharacters(in: .whitespaces)
        return coins[s] ?? (coins.values.contains(s) ? s : nil)
    }

    /// What a message asks the price of: a coin id ("bitcoin"), "SJC" / "PNJ" / "GOLD", or a currency code ("USD").
    /// "giá vàng sjc" → "SJC", "tỷ giá" → "USD", "giá bitcoin" → "bitcoin".
    static let coinWords = ["bitcoin": ["บิตคอยน์", "บิทคอยน์", "ບິດຄອຍ", "ບິດຄອຍນ໌"], "ethereum": ["อีเธอเรียม", "ອີເທີຣຽມ"]]

    static func symbol(in text: String) -> String? {
        let tokens = Token.split(text)
        // Tickers are typed without diacritics: "tốn" is not TON.
        if let coin = tokens.lazy.compactMap({ $0.hasDiacritics ? nil : coinID($0.folded) }).first { return coin }
        // Thai / Lao spellings. ponytail: gold and FX here are Vietnamese (SJC, VND rates); Thai/Lao ones go to web search.
        if let coin = coinWords.first(where: { [Phrase](phrases: $0.value).contained(in: tokens) })?.key { return coin }
        for code in ["SJC", "PNJ"] where tokens.contains(where: { $0.folded == code.lowercased() }) { return code }
        if tokens.contains(where: { $0.matches("vàng") || $0.folded == "gold" }) { return "GOLD" }
        if let code = tokens.lazy.map({ $0.folded.uppercased() }).first(where: fx.contains) { return code }
        if [Phrase](phrases: ["tỷ giá", "đô la", "giá đô", "đô mỹ", "exchange rate", "dollar"]).contained(in: tokens) { return "USD" }
        return nil
    }

    struct Quote: Codable, Equatable {
        struct Price: Codable, Equatable {
            var currency: String
            var price: String
            /// What the price is ("Gold bars 999.9, sell, 1 tael"); nil for a plain crypto price.
            var label: String?
        }
        var symbol: String
        /// CoinGecko id, "gold" or the currency code.
        var coin: String
        /// Display name ("Gold prices", "USD to VND").
        var name: String?
        var prices: [Price]
        var updatedAt: String?
        var source = MarketPrices.sourceName
        /// The page the numbers come from, for the source chip.
        var url: String?
    }

    func quote(_ symbol: String, currency: String, locale: Locale) async throws -> Quote {
        let s = symbol.uppercased().trimmingCharacters(in: .whitespaces)
        if let products = Self.gold[s] ?? (s == "VÀNG" || s == "VANG" ? Self.gold["GOLD"] : nil) {
            return try await goldQuote(s == "SJC" || s == "PNJ" ? s : "GOLD", products: products, locale: locale)
        }
        if Self.coinID(symbol) == nil, Self.fx.contains(s) { return try await fxQuote(s, locale: locale) }
        return try await cryptoQuote(symbol, currency: currency, locale: locale)
    }

    // MARK: Sources

    private func cryptoQuote(_ symbol: String, currency: String, locale: Locale) async throws -> Quote {
        guard let id = Self.coinID(symbol) else {
            throw LLMError("\(symbol) is not a supported symbol: use crypto tickers, SJC, PNJ, GOLD or a currency code; use webSearch for stocks")
        }
        let codes = Array(Set([currency.uppercased(), "USD"])).sorted()
        var c = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        c.queryItems = [.init(name: "ids", value: id), .init(name: "vs_currencies", value: codes.joined(separator: ",").lowercased()),
                        .init(name: "include_last_updated_at", value: "true")]
        let json = try await get(c.url!)
        guard let row = json[id] as? [String: Any] else { throw LLMError("No price for \(id)") }
        let prices = codes.compactMap { code -> Quote.Price? in
            guard let v = (row[code.lowercased()] as? NSNumber)?.decimalValue else { return nil }
            // Sub-unit coins (SHIB) would round to $0.00 in minor units: keep significant digits there.
            let text = v < 1 ? v.formatted(.currency(code: code).locale(locale).precision(.significantDigits(1...4)))
                : Money(major: v, code).formatted(locale: locale)
            return .init(currency: code, price: text)
        }
        let updated = (row["last_updated_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue).formatted(.iso8601) }
        return Quote(symbol: symbol.uppercased(), coin: id, prices: prices, updatedAt: updated,
                     url: "https://www.coingecko.com/en/coins/\(id)")
    }

    /// PNJ quotes thousands of VND per chỉ; Vietnamese gold is talked about per lượng (10 chỉ): Swift converts.
    private func goldQuote(_ symbol: String, products: [String], locale: Locale) async throws -> Quote {
        let json = try await get(URL(string: "https://edge-api.pnj.io/ecom-frontend/v1/get-gold-price?zone=00")!)
        let rows = json["data"] as? [[String: Any]] ?? []
        var prices: [Quote.Price] = []
        for code in products {
            guard let row = rows.first(where: { $0["masp"] as? String == code }), let name = Self.goldNames[code] else { continue }
            for (key, side) in [("giamua", String(localized: "buy", table: "AI")), ("giaban", String(localized: "sell", table: "AI"))] {
                guard let thousandsPerChi = (row[key] as? NSNumber)?.intValue, thousandsPerChi > 0 else { continue }
                prices.append(.init(currency: "VND", price: Money(major: Decimal(thousandsPerChi) * 10_000, "VND").formatted(locale: locale),
                                    label: String(localized: "\(name), \(side), 1 tael", table: "AI")))
            }
        }
        guard !prices.isEmpty else { throw LLMError("No gold prices right now") }
        return Quote(symbol: symbol, coin: "gold", name: String(localized: "Gold prices", table: "AI"), prices: prices,
                     updatedAt: (json["updateDate"] as? String).flatMap(Self.vietnamDate)?.formatted(.iso8601),
                     url: "https://www.pnj.com.vn/site/gia-vang")
    }

    private func fxQuote(_ code: String, locale: Locale) async throws -> Quote {
        var c = URLComponents(string: "https://www.vietcombank.com.vn/api/exchangerates")!
        c.queryItems = [.init(name: "date", value: Date.ISO8601FormatStyle(timeZone: Self.vietnam).year().month().day().format(now()))]
        let json = try await get(c.url!)
        guard let row = (json["Data"] as? [[String: Any]] ?? []).first(where: { $0["currencyCode"] as? String == code }) else {
            throw LLMError("No rate for \(code) right now")
        }
        let prices = [("cash", String(localized: "buy, cash", table: "AI")), ("transfer", String(localized: "buy, transfer", table: "AI")),
                      ("sell", String(localized: "sell", table: "AI"))].compactMap { key, label -> Quote.Price? in
            guard let v = (row[key] as? String).flatMap({ Decimal(string: $0) }), v > 0 else { return nil }
            return .init(currency: "VND", price: Money(major: v, "VND").formatted(locale: locale), label: label)
        }
        guard !prices.isEmpty else { throw LLMError("No rate for \(code) right now") }
        return Quote(symbol: code, coin: code.lowercased(), name: String(localized: "1 \(code) in VND", table: "AI"), prices: prices,
                     updatedAt: (json["UpdatedDate"] as? String).flatMap { try? Date($0, strategy: .iso8601) }?.formatted(.iso8601),
                     url: "https://www.vietcombank.com.vn/vi-VN/KHCN/Cong-cu-Tien-ich/Ty-gia")
    }

    private func get(_ url: URL) async throws -> [String: Any] {
        try await cache.json(url, now: now()) {
            try await HTTP.getJSON(url, headers: ["Accept": "application/json"], timeout: Self.timeout, send: send)
        }
    }

    static let vietnam = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

    /// "06/11/2026 08:39:51", Vietnam time.
    static func vietnamDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = vietnam
        f.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return f.date(from: s)
    }
}

/// Five-minute memory of market replies, by URL.
final class QuoteCache: @unchecked Sendable {
    static let shared = QuoteCache()
    static let ttl: TimeInterval = 300

    private let lock = NSLock()
    private var items: [URL: (at: Date, data: Data)] = [:]

    func json(_ url: URL, now: Date, fetch: () async throws -> [String: Any]) async throws -> [String: Any] {
        if let hit = lock.withLock({ items[url] }), now.timeIntervalSince(hit.at) < Self.ttl,
           let json = try? JSONSerialization.jsonObject(with: hit.data) as? [String: Any] {
            return json
        }
        let json = try await fetch()
        if let data = try? JSONSerialization.data(withJSONObject: json) { lock.withLock { items[url] = (now, data) } }
        return json
    }
}
