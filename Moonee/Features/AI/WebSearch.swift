import Foundation

/// One search result a model can cite.
struct SearchHit: Codable, Equatable, Sendable {
    var title: String
    var url: String
    var text: String
    /// As the source gives it ("2026-11-05", "2 hours ago"); nil when unknown.
    var date: String?
}

/// What `webSearch` returns to the model. `configured == false` means no backend: Moonee explains how to turn search on.
struct SearchResult: Codable, Equatable, Sendable {
    var configured: Bool
    var source: String?
    /// When the search ran (ISO 8601), so answers can say how fresh they are.
    var searchedAt: String
    var results: [SearchHit] = []
    /// The provider's own short answer, when its search returns one.
    var summary: String?
    var message: String?
}

/// Something that can search the web: a BYOK provider's built-in search, or Tavily / Brave with the user's key.
protocol SearchBackend: Sendable {
    var sourceName: String { get }
    func search(_ query: String) async throws -> (hits: [SearchHit], summary: String?)
}

/// The `webSearch` tool's engine. Order (spec §9.3 / roadmap): the selected BYOK provider's built-in search,
/// then the user's Tavily or Brave key, else "not set up".
struct WebSearch: Sendable {
    var backend: (any SearchBackend)?
    var now: @Sendable () -> Date = { .now }

    static let maxHits = 5

    /// Never throws: failures come back as a message the model can relay.
    func run(_ query: String) async -> SearchResult {
        let at = now().formatted(.iso8601)
        guard let backend else {
            return SearchResult(configured: false, searchedAt: at, message:
                "Web search is not set up. Tell the user: open Account → AI assistant → Web search and add a Tavily or Brave key, or use OpenRouter, OpenAI, Anthropic or Gemini as the AI provider.")
        }
        do {
            let r = try await backend.search(query)
            return SearchResult(configured: true, source: backend.sourceName, searchedAt: at,
                                results: Array(r.hits.prefix(Self.maxHits)), summary: r.summary)
        } catch {
            return SearchResult(configured: true, source: backend.sourceName, searchedAt: at, message: "Search failed: \(error.localizedDescription)")
        }
    }

    /// From the settings: provider search only when answers already go to that provider (BYOK / hybrid).
    static func current() -> WebSearch {
        WebSearch(backend: SearchSettings.backend())
    }
}

/// The user's own search key (spec: optional, in Keychain).
enum SearchKeyProvider: String, CaseIterable, Sendable {
    case tavily, brave
    var title: String { self == .tavily ? "Tavily" : "Brave Search" }
    var keychainAccount: String { "search.\(rawValue)" }
}

enum SearchSettings {
    static let providerKey = "ai.search.provider"

    static var keyProvider: SearchKeyProvider? {
        get { SearchKeyProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: providerKey) }
    }

    static func key(_ p: SearchKeyProvider) -> String? { Keychain.get(p.keychainAccount) }
    static func setKey(_ key: String?, for p: SearchKeyProvider) { Keychain.set(key, account: p.keychainAccount) }

    /// Providers whose API has search built in.
    static let providerSearch: Set<CloudProvider> = [.openRouter, .openAI, .anthropic, .gemini]

    static func backend(mode: AIMode = LLMSettings.mode, provider: CloudProvider = LLMSettings.cloudProvider,
                        cloud: (any LLM)? = nil, keyProvider: SearchKeyProvider? = keyProvider,
                        key: (SearchKeyProvider) -> String? = SearchSettings.key, send: @escaping HTTPTransport = HTTP.live) -> (any SearchBackend)? {
        if mode == .byok || mode == .hybrid, providerSearch.contains(provider),
           let llm = (cloud ?? LLMSettings.cloud(provider)) as? any SearchBackend {
            return llm
        }
        guard let keyProvider, let k = key(keyProvider), !k.isEmpty else { return nil }
        return keyProvider == .tavily ? TavilySearch(apiKey: k, send: send) : BraveSearch(apiKey: k, send: send)
    }

    /// Who sees search queries, for "What leaves this iPhone".
    static var note: String {
        guard let b = backend() else {
            return String(localized: "Web search is off. Add a Tavily or Brave key below, or use a provider with built-in search.", table: "AI")
        }
        return String(localized: "When you ask about prices, rates or news, your search query is sent to \(b.sourceName).", table: "AI")
    }
}

// MARK: - Search-key services

struct TavilySearch: SearchBackend {
    var apiKey: String
    var send: HTTPTransport = HTTP.live
    var sourceName: String { "Tavily" }

    func search(_ query: String) async throws -> (hits: [SearchHit], summary: String?) {
        let json = try await HTTP.postJSON(URL(string: "https://api.tavily.com/search")!, headers: ["Authorization": "Bearer \(apiKey)"],
                                           body: ["query": query, "max_results": WebSearch.maxHits, "include_answer": true], send: send)
        let hits = (json["results"] as? [[String: Any]] ?? []).compactMap { r -> SearchHit? in
            guard let url = r["url"] as? String else { return nil }
            return SearchHit(title: r["title"] as? String ?? url, url: url, text: clip(r["content"] as? String), date: r["published_date"] as? String)
        }
        return (hits, json["answer"] as? String)
    }
}

struct BraveSearch: SearchBackend {
    var apiKey: String
    var send: HTTPTransport = HTTP.live
    var sourceName: String { "Brave Search" }

    func search(_ query: String) async throws -> (hits: [SearchHit], summary: String?) {
        var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        c.queryItems = [.init(name: "q", value: query), .init(name: "count", value: String(WebSearch.maxHits))]
        let json = try await HTTP.getJSON(c.url!, headers: ["X-Subscription-Token": apiKey, "Accept": "application/json"], send: send)
        let hits = ((json["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []).compactMap { r -> SearchHit? in
            guard let url = r["url"] as? String else { return nil }
            return SearchHit(title: r["title"] as? String ?? url, url: url, text: clip(r["description"] as? String),
                             date: (r["page_age"] as? String) ?? (r["age"] as? String))
        }
        return (hits, nil)
    }
}

// MARK: - Built-in search of BYOK providers

private let searchPrompt = "Search the web and answer briefly with facts and numbers, citing your sources: "

extension OpenAICompatibleLLM: SearchBackend {
    var sourceName: String { provider == .openAI ? "OpenAI" : "OpenRouter" }

    /// OpenRouter: the `web` plugin, results in `url_citation` annotations. OpenAI: the Responses API `web_search` tool.
    func search(_ query: String) async throws -> (hits: [SearchHit], summary: String?) {
        let base = baseURL.trimmingCharacters(in: .init(charactersIn: "/ "))
        let auth = ["Authorization": "Bearer \(apiKey)"]
        switch provider {
        case .openRouter:
            let json = try await HTTP.postJSON(URL(string: base + "/chat/completions")!, headers: auth, body: [
                "model": model, "plugins": [["id": "web", "max_results": WebSearch.maxHits]],
                "messages": [["role": "user", "content": searchPrompt + query]],
            ], send: send)
            let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] ?? [:]
            let hits = (message["annotations"] as? [[String: Any]] ?? []).compactMap { a -> SearchHit? in
                guard let c = a["url_citation"] as? [String: Any], let url = c["url"] as? String else { return nil }
                return SearchHit(title: c["title"] as? String ?? url, url: url, text: clip(c["content"] as? String))
            }
            return (unique(hits), message["content"] as? String)
        case .openAI:
            let json = try await HTTP.postJSON(URL(string: base + "/responses")!, headers: auth, body: [
                "model": model, "tools": [["type": "web_search"]], "input": searchPrompt + query,
            ], send: send)
            var hits: [SearchHit] = [], summary = ""
            for item in json["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    let text = part["text"] as? String ?? ""
                    summary += text
                    for a in part["annotations"] as? [[String: Any]] ?? [] where a["type"] as? String == "url_citation" {
                        guard let url = a["url"] as? String else { continue }
                        hits.append(SearchHit(title: a["title"] as? String ?? url, url: url,
                                              text: clip(cited(text, a["start_index"] as? Int, a["end_index"] as? Int))))
                    }
                }
            }
            return (unique(hits), summary.isEmpty ? nil : summary)
        default:
            throw LLMError("\(provider.rawValue) has no built-in web search")
        }
    }
}

extension AnthropicLLM: SearchBackend {
    var sourceName: String { "Anthropic" }

    /// The server-side `web_search` tool; snippets come from the answer's citations, dates from the results.
    func search(_ query: String) async throws -> (hits: [SearchHit], summary: String?) {
        let json = try await HTTP.postJSON(URL(string: baseURL + "/v1/messages")!, headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"], body: [
            "model": model, "max_tokens": 1024,
            "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]],
            "messages": [["role": "user", "content": searchPrompt + query]],
        ], send: send)
        let blocks = json["content"] as? [[String: Any]] ?? []
        var ages: [String: String] = [:]
        for b in blocks where b["type"] as? String == "web_search_tool_result" {
            for r in b["content"] as? [[String: Any]] ?? [] {
                if let url = r["url"] as? String, let age = r["page_age"] as? String { ages[url] = age }
            }
        }
        var hits: [SearchHit] = [], summary = ""
        for b in blocks where b["type"] as? String == "text" {
            summary += b["text"] as? String ?? ""
            for c in b["citations"] as? [[String: Any]] ?? [] {
                guard let url = c["url"] as? String else { continue }
                hits.append(SearchHit(title: c["title"] as? String ?? url, url: url, text: clip(c["cited_text"] as? String), date: ages[url]))
            }
        }
        return (unique(hits), summary.isEmpty ? nil : summary)
    }
}

extension GeminiLLM: SearchBackend {
    var sourceName: String { "Google Search (Gemini)" }

    /// `google_search` grounding: sources in `groundingChunks`, the text they back in `groundingSupports`.
    func search(_ query: String) async throws -> (hits: [SearchHit], summary: String?) {
        let json = try await HTTP.postJSON(URL(string: "\(baseURL)/models/\(model):generateContent")!, headers: ["x-goog-api-key": apiKey], body: [
            "contents": [["role": "user", "parts": [["text": searchPrompt + query]]]],
            "tools": [["google_search": [String: Any]()]],
        ], send: send)
        let candidate = (json["candidates"] as? [[String: Any]])?.first ?? [:]
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let meta = candidate["groundingMetadata"] as? [String: Any] ?? [:]
        let chunks = (meta["groundingChunks"] as? [[String: Any]] ?? []).map { $0["web"] as? [String: Any] ?? [:] }
        var texts: [Int: String] = [:]
        for s in meta["groundingSupports"] as? [[String: Any]] ?? [] {
            let text = (s["segment"] as? [String: Any])?["text"] as? String ?? ""
            for i in s["groundingChunkIndices"] as? [Int] ?? [] where texts[i] == nil { texts[i] = text }
        }
        let hits = chunks.enumerated().compactMap { i, web -> SearchHit? in
            guard let url = web["uri"] as? String else { return nil }
            return SearchHit(title: web["title"] as? String ?? url, url: url, text: clip(texts[i]))
        }
        let summary = parts.compactMap { $0["text"] as? String }.joined()
        return (unique(hits), summary.isEmpty ? nil : summary)
    }
}

private func clip(_ s: String?) -> String {
    let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return t.count > 500 ? String(t.prefix(500)) + "…" : t
}

private func cited(_ text: String, _ start: Int?, _ end: Int?) -> String {
    guard let start, let end, start >= 0, end <= text.count, start < end else { return "" }
    return String(text.dropFirst(start).prefix(end - start))
}

/// One hit per URL, first one wins.
private func unique(_ hits: [SearchHit]) -> [SearchHit] {
    var seen = Set<String>()
    return hits.filter { seen.insert($0.url).inserted }
}

// MARK: - Crypto prices

/// Keyless crypto prices from CoinGecko's public `simple/price`. Gold, stocks and FX go through `webSearch`
/// (no scraping of sites with unclear terms).
struct MarketPrices: Sendable {
    var send: HTTPTransport = HTTP.live

    /// Ticker → CoinGecko id. Names ("bitcoin") and CoinGecko ids are accepted too.
    static let coins: [String: String] = [
        "btc": "bitcoin", "eth": "ethereum", "usdt": "tether", "usdc": "usd-coin", "bnb": "binancecoin", "sol": "solana",
        "xrp": "ripple", "ada": "cardano", "doge": "dogecoin", "ton": "the-open-network", "trx": "tron", "dot": "polkadot",
        "ltc": "litecoin", "link": "chainlink", "avax": "avalanche-2", "shib": "shiba-inu",
    ]

    static func coinID(_ symbol: String) -> String? {
        let s = symbol.lowercased().trimmingCharacters(in: .whitespaces)
        return coins[s] ?? (coins.values.contains(s) ? s : nil)
    }

    /// The first coin named in a message ("giá bitcoin hôm nay" → "bitcoin").
    static func symbol(in text: String) -> String? {
        Token.split(text).lazy.compactMap { coinID($0.folded) }.first
    }

    struct Quote: Codable, Equatable {
        struct Price: Codable, Equatable { var currency: String; var price: String }
        var symbol: String
        var coin: String
        var prices: [Price]
        var updatedAt: String?
        var source = "CoinGecko"
    }

    /// Prices in `currency` (the user's) and USD, formatted with `Money`.
    func quote(_ symbol: String, currency: String, locale: Locale) async throws -> Quote {
        guard let id = Self.coinID(symbol) else {
            throw LLMError("\(symbol) is not a supported crypto symbol; use webSearch for gold, stocks and exchange rates")
        }
        let codes = Array(Set([currency.uppercased(), "USD"])).sorted()
        var c = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        c.queryItems = [.init(name: "ids", value: id), .init(name: "vs_currencies", value: codes.joined(separator: ",").lowercased()),
                        .init(name: "include_last_updated_at", value: "true")]
        let json = try await HTTP.getJSON(c.url!, headers: ["Accept": "application/json"], send: send)
        guard let row = json[id] as? [String: Any] else { throw LLMError("No price for \(id)") }
        let prices = codes.compactMap { code -> Quote.Price? in
            guard let v = (row[code.lowercased()] as? NSNumber)?.decimalValue else { return nil }
            // Sub-unit coins (SHIB) would round to $0.00 in minor units: keep significant digits there.
            let text = v < 1 ? v.formatted(.currency(code: code).locale(locale).precision(.significantDigits(1...4)))
                : Money(major: v, code).formatted(locale: locale)
            return .init(currency: code, price: text)
        }
        let updated = (row["last_updated_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue).formatted(.iso8601) }
        return Quote(symbol: symbol.uppercased(), coin: id, prices: prices, updatedAt: updated)
    }
}
