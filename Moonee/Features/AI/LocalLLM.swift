import Foundation
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
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

    /// The model the user picked on the models screen, once downloaded.
    static var current: LocalLLM? {
        let store = LocalModelStore.shared
        guard isSupported, let m = LocalModel.find(UserDefaults.standard.string(forKey: LocalModelDownloads.selectedKey)),
              store.isDownloaded(m) else { return nil }
        return LocalLLM(model: m, folder: store.folder(m))
    }

    func respond(_ r: LLMRequest) async throws -> String {
        let container = try await LocalRuntime.shared.container(folder)
        let session = ChatSession(container, instructions: r.system,
                                  generateParameters: GenerateParameters(maxTokens: 600, temperature: 0.3),
                                  additionalContext: Self.noThinking)
        return try await session.respond(to: AppleLLM.prompt(r.messages))
    }

    func extractTransactions(instructions: String, text: String) async throws -> [AIParsedTxn] {
        let (container, guide) = try await LocalRuntime.shared.loaded(folder)
        let json = try await container.perform { context in
            let constraint = try guide.constraint(hostTokenizer: context.tokenizer)
            let input = try await context.processor.prepare(input: UserInput(
                chat: [.system(instructions), .user(text)], additionalContext: Self.noThinking))
            var out = ""
            // Same safeguards as mlx-swift-lm's FoundationModels adapter: push toward closing the JSON near the
            // token budget and damp whitespace runs, which otherwise eat the budget (`incompleteOutput`).
            try GuidedGenerationLoop.run(input: input, context: context, constraint: constraint, maxTokens: Self.maxTokens,
                                         vocabSize: guide.tokenizer.vocabSize,
                                         completionReserve: max(guide.reserve * 3, Self.maxTokens / 4),
                                         hardReserve: guide.reserve * 8, closingBias: guide.closingBias,
                                         whitespaceBias: guide.whitespaceBias, whitespaceTokenIDs: guide.whitespaceTokenIDs) { delta in
                out += delta
                return !Task.isCancelled
            }
            return out
        }
        return try AIParsedTxn.decodeList(json)
    }

    private static let maxTokens = 400

    /// Qwen3.5 would think out loud first; parsing and short answers don't need it. Other templates ignore the flag.
    private static let noThinking: [String: any Sendable] = ["enable_thinking": false]
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

/// Holds at most one loaded model. Loads on first use, unloads when the app goes to the background
/// (spec §9.2: battery, heat, and iOS forbids GPU work in the background).
actor LocalRuntime {
    static let shared: LocalRuntime = {
        let runtime = LocalRuntime()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            Task { await runtime.unload() }
        }
        #endif
        return runtime
    }()

    private var loaded: (folder: URL, container: ModelContainer, guide: JSONGuide)?

    func container(_ folder: URL) async throws -> ModelContainer { try await loaded(folder).container }

    func loaded(_ folder: URL) async throws -> (container: ModelContainer, guide: JSONGuide) {
        if let loaded, loaded.folder == folder { return (loaded.container, loaded.guide) }
        unload()
        Memory.cacheLimit = 64 * 1024 * 1024 // keep MLX's buffer cache small on a phone
        let container = try await loadModelContainer(from: folder, using: TransformersTokenizerLoader())
        let guide = try await container.perform { try JSONGuide($0.tokenizer) }
        loaded = (folder, container, guide)
        return (container, guide)
    }

    func unload() {
        loaded = nil
        Memory.clearCache()
    }
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
