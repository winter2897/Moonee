import Foundation

/// One transaction as a model reads it. Money and dates stay as the user's words: Swift turns them into numbers
/// (`TransactionExtractor`), so a model can never invent an amount.
struct AIParsedTxn: Codable, Equatable, Sendable {
    /// The money words copied exactly from the message, e.g. "45k", "1tr2", "$12". Never convert or compute. Null if the message has no amount.
    var amountText: String?
    /// expense, income, transfer (between wallets), jarTransfer (between jars), lend, borrow or repay
    var kind: String
    /// A category key from the list, only for expense or income
    var category: String?
    /// Wallet paid from or moved from, a name from the list
    var wallet: String?
    /// Wallet moved to, a name from the list
    var toWallet: String?
    /// Jar moved from, a jar key from the list
    var jar: String?
    /// Jar moved to, a jar key from the list
    var toJar: String?
    /// The other person when lending, borrowing or repaying, as written
    var person: String?
    /// Date words copied exactly from the message, e.g. "hôm qua", "last monday". Null if none.
    var dateText: String?
    /// A short note in the user's words, without the amount and date words
    var note: String
}

struct AIParsedTxnList: Codable, Sendable {
    var transactions: [AIParsedTxn]
}

extension AIParsedTxn {
    /// JSON shape for cloud models (same keys as `AIParsedTxn`).
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
