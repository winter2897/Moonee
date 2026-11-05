import Foundation
import FoundationModels

/// Apple Foundation Models (iOS 26, Apple Intelligence devices). Small: gets short skills and pre-computed facts.
/// ponytail: on-device tool calling is unreliable in Vietnamese (tested on macOS 27), so `Assistant` only gives it tools' results.
struct AppleLLM: LLM {
    var isSmall: Bool { true }

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    func respond(_ r: LLMRequest) async throws -> String {
        let session = LanguageModelSession(tools: try r.tools.map(FoundationTool.init), instructions: r.system)
        return try await session.respond(to: Self.prompt(r.messages)).content
    }

    func extractTransactions(instructions: String, text: String) async throws -> [AIParsedTxn] {
        try await LanguageModelSession(instructions: instructions).respond(to: text, generating: AIParsedTxnList.self).content.transactions
    }

    /// Earlier turns go inline: small models do better with one flat prompt than a long transcript.
    static func prompt(_ messages: [LLMMessage]) -> String {
        guard let last = messages.last else { return "" }
        guard messages.count > 1 else { return last.text }
        let earlier = messages.dropLast().map { "\($0.role == .user ? "User" : "Moonee"): \($0.text)" }.joined(separator: "\n")
        return "Earlier in this chat:\n\(earlier)\n\nNow: \(last.text)"
    }
}

/// An `AITool` as a Foundation Models tool.
struct FoundationTool: Tool {
    let tool: AITool
    let parameters: GenerationSchema
    var name: String { tool.name }
    var description: String { tool.description }

    init(_ tool: AITool) throws {
        self.tool = tool
        parameters = try GenerationSchema(root: tool.parameters.dynamic(name: tool.name), dependencies: [])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        await [tool].call(tool.name, arguments: Data(arguments.jsonString.utf8))
    }
}

/// One transaction as a model reads it. Money and dates stay as the user's words: Swift turns them into numbers
/// (`TransactionExtractor`), so a model can never invent an amount.
@Generable(description: "One transaction in the user's message")
struct AIParsedTxn: Codable, Equatable, Sendable {
    @Guide(description: "The money words copied exactly from the message, e.g. \"45k\", \"1tr2\", \"$12\". Never convert or compute. Null if the message has no amount.")
    var amountText: String?
    @Guide(description: "expense, income, transfer (between wallets), jarTransfer (between jars), lend, borrow or repay",
           .anyOf(EntryKind.allCases.map(\.rawValue)))
    var kind: String
    @Guide(description: "A category key from the list, only for expense or income")
    var category: String?
    @Guide(description: "Wallet paid from or moved from, a name from the list")
    var wallet: String?
    @Guide(description: "Wallet moved to, a name from the list")
    var toWallet: String?
    @Guide(description: "Jar moved from, a jar key from the list")
    var jar: String?
    @Guide(description: "Jar moved to, a jar key from the list")
    var toJar: String?
    @Guide(description: "The other person when lending, borrowing or repaying, as written")
    var person: String?
    @Guide(description: "Date words copied exactly from the message, e.g. \"hôm qua\", \"last monday\". Null if none.")
    var dateText: String?
    @Guide(description: "A short note in the user's words, without the amount and date words")
    var note: String
}

@Generable
struct AIParsedTxnList: Codable, Sendable {
    var transactions: [AIParsedTxn]
}

extension AIParsedTxn {
    /// JSON shape for cloud models (same keys as the `@Generable` schema; a test keeps them in sync).
    static let jsonInstructions = """
        Reply with JSON only, in this shape (null for unknown fields):
        {"transactions":[{"amountText":"45k","kind":"expense","category":"category.food","wallet":null,"toWallet":null,\
        "jar":null,"toJar":null,"person":null,"dateText":"hôm qua","note":"phở"}]}
        """

    /// Takes the outermost JSON object (models like ```json fences and prose around it).
    static func decodeList(_ reply: String) throws -> [AIParsedTxn] {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let list = try? JSONDecoder().decode(AIParsedTxnList.self, from: Data(reply[start...end].utf8))
        else { throw LLMError("The model did not return transaction JSON") }
        return list.transactions
    }
}
