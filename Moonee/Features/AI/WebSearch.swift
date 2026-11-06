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
    /// The user's switch (`LLMSettings.webSearch`, also in the chat composer). Off = nothing is searched.
    var enabled = true

    static let maxHits = 5

    /// Never throws: failures come back as a message the model can relay.
    func run(_ query: String) async -> SearchResult {
        let at = now().formatted(.iso8601)
        guard enabled else {
            return SearchResult(configured: false, searchedAt: at, message:
                "The user turned web search off. Answer without outside data, and say they can turn search on in the chat or in Account → AI assistant.")
        }
        guard let backend else {
            return SearchResult(configured: false, searchedAt: at, message:
                "Web search is not set up. Gold, exchange rates and crypto still work through marketPrice. For anything else tell the user: open Account → AI assistant → Web search and add a Tavily or Brave key, or use OpenRouter, OpenAI, Anthropic or Gemini as the AI provider.")
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
        WebSearch(backend: SearchSettings.backend(), enabled: LLMSettings.webSearch)
    }
}

/// A web source behind an answer, for the chat's source chips.
struct WebSource: Equatable, Hashable, Sendable {
    var title: String
    var url: URL
    /// Host without "www." ("sjc.com.vn").
    var site: String
    /// Parsed when the source gives an ISO-style date; nil for "2 hours ago" and the like.
    var date: Date?

    init?(_ hit: SearchHit) {
        guard let url = URL(string: hit.url), let host = url.host() else { return nil }
        title = hit.title
        self.url = url
        site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        date = hit.date.flatMap(WebSource.date(from:))
    }

    init(title: String, url: URL, site: String, date: Date? = nil) {
        (self.title, self.url, self.site, self.date) = (title, url, site, date)
    }

    static func date(from s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "MMMM d, yyyy", "EEE, dd MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

/// Collects the hits `webSearch` returned while one answer was made.
final class SourceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [SearchHit] = []

    var sources: [WebSource] {
        lock.withLock {
            var seen = Set<String>()
            return hits.filter { seen.insert($0.url).inserted }.compactMap(WebSource.init)
        }
    }

    /// The same tool, recording the pages it hands to the model (search hits, the price source). Other tools pass through.
    func wrap(_ tool: AITool) -> AITool {
        guard tool.name == "webSearch" || tool.name == "marketPrice" else { return tool }
        return AITool(name: tool.name, description: tool.description, parameters: tool.parameters) { [self] data in
            let out = try await tool.run(data)
            let found: [SearchHit]
            if let r = try? JSONDecoder().decode(SearchResult.self, from: Data(out.utf8)) {
                found = r.results
            } else if let q = try? JSONDecoder().decode(MarketPrices.Quote.self, from: Data(out.utf8)), let url = q.url {
                found = [SearchHit(title: q.name ?? q.source, url: url, text: "", date: q.updatedAt)]
            } else {
                found = []
            }
            lock.withLock { hits += found }
            return out
        }
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
            return String(localized: "Gold prices, exchange rates and crypto come from PNJ, Vietcombank and CoinGecko; only the item you ask about is sent, never your data.", table: "AI")
        }
        return String(localized: "When you ask about prices, rates or news, your search query is sent to \(b.sourceName).", table: "AI")
    }

    /// Which way web questions go right now, for the Web search section of AI settings.
    static var route: String {
        let base = String(localized: "Gold, exchange rates and crypto always come from PNJ, Vietcombank and CoinGecko, no key needed.", table: "AI")
        guard LLMSettings.webSearch else { return String(localized: "Web search is off.", table: "AI") + " " + base }
        guard let b = backend() else {
            return base + " " + String(localized: "For other questions (stocks, interest rates, news), add a Tavily or Brave key, or use OpenRouter, OpenAI, Anthropic or Gemini.", table: "AI")
        }
        let way = b is TavilySearch || b is BraveSearch
            ? String(localized: "Searching with your \(b.sourceName) key.", table: "AI")
            : String(localized: "Searching with \(b.sourceName)'s built-in search.", table: "AI")
        return way + " " + base
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
