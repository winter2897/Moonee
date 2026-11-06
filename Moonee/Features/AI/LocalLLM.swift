import Foundation
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import os
import Tokenizers
#if canImport(UIKit)
import UIKit
#endif

/// A downloaded open model run with MLX Swift (spec §9.1 "Model local", §9.2). Small: gets short skills and
/// pre-computed facts, like `AppleLLM`. Transaction parsing is grammar-constrained to the `AIParsedTxnList` JSON
/// schema, then `TransactionExtractor` validates it as for every other model.
struct LocalLLM: LLM {
    let model: LocalModel
    let folder: URL

    var isSmall: Bool { true }

    /// MLX needs a real Metal GPU: the iOS Simulator cannot run it.
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    /// The model the user picked on the models screen, once downloaded. In local/hybrid mode this also starts
    /// loading it in the background, so the first message does not wait for the load (the router asks for it
    /// when the chat opens).
    static var current: LocalLLM? {
        let store = LocalModelStore.shared
        guard isSupported, let m = LocalModel.find(UserDefaults.standard.string(forKey: LocalModelDownloads.selectedKey)),
              store.isDownloaded(m) else { return nil }
        let llm = LocalLLM(model: m, folder: store.folder(m))
        if LLMSettings.mode == .local || LLMSettings.mode == .hybrid {
            Task { await LocalRuntime.shared.prewarm(llm.folder) }
        }
        return llm
    }

    func respond(_ r: LLMRequest) async throws -> String {
        // Small models only think when asked to work hard; otherwise they spend the budget thinking out loud.
        let think = model.thinking && r.effort.map { [.high, .higher, .max].contains($0) } == true
        return try await LocalRuntime.shared.chat(folder, system: r.system, messages: r.messages, thinking: think,
                                                  maxTokens: think ? 1200 : Self.maxAnswerTokens, onPartial: r.onPartial)
    }

    func extractTransactions(instructions: String, text: String) async throws -> [AIParsedTxn] {
        let (container, guide) = try await LocalRuntime.shared.loaded(folder)
        let json = try await container.perform { context in
            let constraint = try guide.constraint(hostTokenizer: context.tokenizer)
            let input = try await context.processor.prepare(input: UserInput(
                chat: [.system(instructions), .user(text)], additionalContext: LocalRuntime.context(thinking: false)))
            var out = ""
            // Same safeguards as mlx-swift-lm's FoundationModels adapter: push toward closing the JSON near the
            // token budget and damp whitespace runs, which otherwise eat the budget (`incompleteOutput`).
            try GuidedGenerationLoop.run(input: input, context: context, constraint: constraint, maxTokens: Self.maxParseTokens,
                                         vocabSize: guide.tokenizer.vocabSize,
                                         completionReserve: max(guide.reserve * 3, Self.maxParseTokens / 4),
                                         hardReserve: guide.reserve * 8, closingBias: guide.closingBias,
                                         whitespaceBias: guide.whitespaceBias, whitespaceTokenIDs: guide.whitespaceTokenIDs) { delta in
                out += delta
                return !Task.isCancelled
            }
            return out
        }
        return try AIParsedTxn.decodeList(json)
    }

    private static let maxParseTokens = 400
    /// Chat answers are a few sentences; a lower cap bounds the worst-case wait on a phone (~10 s at 30 tok/s).
    static let maxAnswerTokens = 320

    /// Speed on this phone: a fixed Vietnamese question with a typical system prompt, from a loaded model.
    func benchmark() async throws -> LocalRuntime.Metrics {
        _ = try await LocalRuntime.shared.loaded(folder)
        await LocalRuntime.shared.reset()
        _ = try await LocalRuntime.shared.chat(folder, system: Self.benchmarkSystem, messages: [.init(role: .user, text: Self.benchmarkQuestion)],
                                               thinking: false, maxTokens: 128, onPartial: nil)
        guard let m = await LocalRuntime.shared.lastMetrics else { throw LLMError("No answer") }
        return m
    }

    static let benchmarkSystem = String(repeating: "Bạn là Moonee, trợ lý tài chính cá nhân. Trả lời ngắn gọn bằng tiếng Việt, dùng đúng số liệu được cho. ", count: 8)
    static let benchmarkQuestion = "Giải thích ngắn gọn cách chia thu nhập vào 6 lọ."
}

extension AIParsedTxn {
    /// The `@Generable` shape as JSON Schema, for grammar-constrained decoding. Every key is required (nullable)
    /// so the grammar fast-forwards the keys and the model only writes values.
    static let jsonSchema: String = {
        // Short caps keep small models from rambling inside a string until the token budget runs out.
        func nullable(_ d: String) -> [String: Any] { ["type": ["string", "null"], "maxLength": 40, "description": d] }
        let item: [String: Any] = [
            "type": "object",
            "properties": [
                "amountText": nullable("money words copied exactly from the message"),
                "kind": ["type": "string", "enum": EntryKind.allCases.map(\.rawValue)],
                "category": nullable("category key"),
                "wallet": nullable("wallet name"),
                "toWallet": nullable("wallet name"),
                "jar": nullable("jar key"),
                "toJar": nullable("jar key"),
                "person": nullable("other person"),
                "dateText": nullable("date words copied exactly"),
                "note": ["type": "string", "maxLength": 60],
            ],
            "required": ["amountText", "kind", "category", "wallet", "toWallet", "jar", "toJar", "person", "dateText", "note"],
            "additionalProperties": false,
        ]
        let root: [String: Any] = [
            "type": "object",
            "properties": ["transactions": ["type": "array", "items": item, "minItems": 1, "maxItems": 8]],
            "required": ["transactions"],
            "additionalProperties": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }()
}

/// Holds at most one loaded model, between messages too. Loads on first use (or ahead, `prewarm`), unloads when the
/// app goes to the background (spec §9.2: battery, heat, and iOS forbids GPU work in the background) and loads it
/// again when the app comes back.
actor LocalRuntime {
    static let shared: LocalRuntime = {
        let runtime = LocalRuntime()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            Task { await runtime.unload(keepForReturn: true) }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            Task { await runtime.reloadAfterBackground() }
        }
        #endif
        return runtime
    }()

    struct Metrics: Sendable, Equatable {
        /// Send → first answer token (prompt processing + first decode step).
        var firstToken: Duration
        var tokensPerSecond: Double
        var promptTokens: Int
        /// Prompt tokens a kept KV cache already held, so they were not processed again.
        var reusedPromptTokens: Int

        var firstTokenSeconds: Double { Double(firstToken.components.seconds) + Double(firstToken.components.attoseconds) / 1e18 }
    }

    private var loaded: (folder: URL, container: ModelContainer, guide: JSONGuide)?
    private var loading: (folder: URL, task: Task<(ModelContainer, JSONGuide), Error>)?
    private var returnTo: URL?
    /// The chat turn the KV cache holds: same system prompt and the same earlier turns → only the new message is
    /// processed (prefix reuse inside `ChatSession`).
    private var session: (key: String, transcript: [LLMMessage], chat: ChatSession)?
    private(set) var lastMetrics: Metrics?
    private let log = Logger(subsystem: "Moonee", category: "LocalLLM")

    func loaded(_ folder: URL) async throws -> (container: ModelContainer, guide: JSONGuide) {
        if let loaded, loaded.folder == folder { return (loaded.container, loaded.guide) }
        if let loading, loading.folder == folder { return try await loading.task.value }
        unload()
        // ponytail: 64 MB buffer cache; MLX's iOS examples use 20 MB. Bigger only helps long answers, and costs RAM.
        Memory.cacheLimit = 64 * 1024 * 1024
        let task = Task {
            let container = try await loadModelContainer(from: folder, using: TransformersTokenizerLoader())
            let guide = try await container.perform { try JSONGuide($0.tokenizer) }
            return (container, guide)
        }
        loading = (folder, task)
        defer { loading = nil }
        let t0 = ContinuousClock.now
        let (container, guide) = try await task.value
        log.info("loaded \(folder.lastPathComponent, privacy: .public) in \(ContinuousClock.now - t0, privacy: .public)")
        loaded = (folder, container, guide)
        return (container, guide)
    }

    /// Load and run one token so the first real message skips the load and Metal's shader warm-up.
    func prewarm(_ folder: URL) async {
        guard loaded?.folder != folder, loading?.folder != folder,
              let (container, _) = try? await loaded(folder) else { return }
        _ = try? await ChatSession(container, generateParameters: GenerateParameters(maxTokens: 1),
                                   additionalContext: Self.context(thinking: false)).respond(to: "Hi")
    }

    /// One chat answer, streamed to `onPartial` (the text so far).
    func chat(_ folder: URL, system: String, messages: [LLMMessage], thinking: Bool, maxTokens: Int,
              onPartial: (@Sendable (String) -> Void)?) async throws -> String {
        let (container, _) = try await loaded(folder)
        guard let last = messages.last else { return "" }
        let earlier = Array(messages.dropLast())
        let key = "\(folder.path)|\(thinking)|\(maxTokens)|\(system)"
        let chat: ChatSession
        if let session, session.key == key, session.transcript == earlier {
            chat = session.chat
        } else {
            chat = ChatSession(container, instructions: system, history: earlier.map(Self.message),
                               generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3),
                               additionalContext: Self.context(thinking: thinking))
        }
        session = nil // until this turn completes, the cache holds a partial turn
        let t0 = ContinuousClock.now
        var first: Duration?, text = "", info: GenerateCompletionInfo?
        for try await g in chat.streamDetails(to: last.text, images: [], videos: []) {
            switch g {
            case .chunk(let c):
                if first == nil { first = ContinuousClock.now - t0 }
                text += c
                onPartial?(text)
            case .info(let i): info = i
            default: break
            }
        }
        if let info {
            let m = Metrics(firstToken: first ?? (ContinuousClock.now - t0), tokensPerSecond: info.tokensPerSecond,
                            promptTokens: info.promptTokenCount, reusedPromptTokens: info.cachedPromptTokenCount)
            lastMetrics = m
            log.info("first token \(m.firstToken, privacy: .public), \(Int(m.tokensPerSecond)) tok/s, prompt \(m.promptTokens) (\(m.reusedPromptTokens) reused)")
        }
        session = (key, earlier + [last, .init(role: .assistant, text: text)], chat)
        return text
    }

    /// Forget the kept chat turn (the next answer processes its whole prompt).
    func reset() { session = nil }

    func unload() { unload(keepForReturn: false) }

    private func unload(keepForReturn: Bool) {
        returnTo = keepForReturn ? loaded?.folder : nil
        loading?.task.cancel()
        loading = nil
        session = nil
        loaded = nil
        Memory.clearCache()
    }

    private func reloadAfterBackground() async {
        guard let folder = returnTo else { return }
        returnTo = nil
        await prewarm(folder)
    }

    static func message(_ m: LLMMessage) -> Chat.Message { m.role == .user ? .user(m.text) : .assistant(m.text) }

    /// Qwen 3.5, Gemma 4, MiniCPM 5 read `enable_thinking`; other templates ignore it.
    static func context(thinking: Bool) -> [String: any Sendable] { ["enable_thinking": thinking] }
}

/// Per-model pieces of grammar-constrained decoding, built once per load (the vocab scans take a moment).
final class JSONGuide: @unchecked Sendable {
    let tokenizer: GrammarTokenizer
    let closingBias: MLXArray
    let whitespaceBias: MLXArray
    let whitespaceTokenIDs: Set<Int>
    let reserve: Int
    private let template: GrammarConstraint

    init(_ host: any MLXLMCommon.Tokenizer) throws {
        let vocab = TokenizerVocabExtractor.extractForGrammar(from: host)
        tokenizer = try GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType, eosTokenId: Int32(host.eosTokenId ?? 0))
        closingBias = ClosingTokenBias.compute(tokenizer: host, eosTokenId: host.eosTokenId)
        (whitespaceBias, whitespaceTokenIDs) = WhitespaceTokenBias.compute(tokenizer: host)
        reserve = CompletionReserve.estimate(schemaJSON: AIParsedTxn.jsonSchema, tokenizer: host)
        template = try GrammarConstraint(tokenizer: tokenizer, jsonSchema: AIParsedTxn.jsonSchema, fastForward: true, hostTokenizer: host)
    }

    /// A fresh matcher for one request (cloning skips recompiling the schema).
    func constraint(hostTokenizer: any MLXLMCommon.Tokenizer) throws -> GrammarConstraint {
        if let clone = try? template.clone() { return clone }
        return try GrammarConstraint(tokenizer: tokenizer, jsonSchema: AIParsedTxn.jsonSchema, fastForward: true, hostTokenizer: hostTokenizer)
    }
}

/// swift-transformers' tokenizer behind mlx-swift-lm's protocol (what the MLXHuggingFace macros expand to,
/// without pulling in their swift-syntax build).
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        Bridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }

    struct Bridge: MLXLMCommon.Tokenizer {
        let upstream: any Tokenizers.Tokenizer

        func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }

        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            do {
                return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
            } catch Tokenizers.TokenizerError.missingChatTemplate {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        }
    }
}
