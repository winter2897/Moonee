import Foundation
import FoundationModels

// Photos and screenshots of money documents read by a model (skill `receipt-reader`, spec §9.3): cloud vision models
// see the image and the OCR rows, on-device models the OCR rows with their layout. Every amount the model gives must
// be on the page; dates must be sane; anything else falls back to `DocumentReader`'s rules.

/// A model's reading of a document, as words copied from it.
struct AIDocRead: Codable, Equatable, Sendable {
    var docType: String
    var transactions: [Txn]

    struct Txn: Codable, Equatable, Sendable {
        var amountText: String?
        var currency: String?
        var kind: String
        var counterparty: String?
        var dateText: String?
        var wallet: String?
        var reference: String?
        var category: String?
        var confidence: Double?
        var note: String?
    }

    init(docType: String, transactions: [Txn]) { (self.docType, self.transactions) = (docType, transactions) }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        docType = try c.decode(String.self, forKey: .docType)
        transactions = try c.decodeIfPresent([Txn].self, forKey: .transactions) ?? [] // "other" often comes with null
    }

    static let jsonInstructions = """
        Reply with JSON only, in this shape (null for unknown fields):
        {"docType":"payment","transactions":[{"amountText":"32.000 đ","currency":"VND","kind":"sent",\
        "counterparty":"Nguyễn Văn An","dateText":"19:38 - 05/11/2026","wallet":"MoMo","reference":"155310026979",\
        "category":null,"confidence":0.9,"note":null}]}
        """

    /// Takes the outermost JSON object (models like ```json fences and prose around it).
    static func decode(_ reply: String) throws -> AIDocRead {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let read = try? JSONDecoder().decode(AIDocRead.self, from: Data(reply[start...end].utf8))
        else { throw LLMError("The model did not return document JSON") }
        return read
    }
}

extension Skill {
    static let receiptReader = Skill(id: "receipt-reader", tools: [], job: .parse)
}

/// Checks a model's reading against the page. Nil = don't trust it (the caller uses the rules).
enum DocumentExtractor {
    static func validate(_ ai: AIDocRead, lines: [OCRLine], rules: DocRead, context: ParserContext) -> DocRead? {
        guard let type = DocType(rawValue: ai.docType) else { return nil }
        // "Not money" only when the rules saw no confirmation, bill or statement either.
        if type == .other { return [.other, .receipt].contains(rules.type) ? DocRead(type: .other, items: []) : nil }

        let page = squeeze(lines.map(\.text).joined(separator: " "))
        let seen = Set(DocumentReader.amounts(in: lines, context: context))
        func quoted(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.lowercased() != "null",
                  page.contains(squeeze(s)) else { return nil }
            return s
        }

        var items: [DocRead.Item] = []
        for t in ai.transactions {
            // Every amount must be one the page shows: nothing invented, nothing computed.
            guard let kind = DocRead.Kind(rawValue: t.kind), let text = quoted(t.amountText),
                  let money = QuickParser.amount(in: text, context: context), seen.contains(money.amount) else { return nil }
            if let c = t.confidence, c < 0.3 { continue }
            let twin = rules.items.first { $0.amount == money.amount }
            var item = DocRead.Item(amount: money.amount, currency: money.currency, kind: kind)
            item.date = quoted(t.dateText).flatMap { DocumentReader.date(in: $0, context: context) } ?? twin?.date
            item.counterparty = quoted(t.counterparty) ?? twin?.counterparty
            item.wallet = t.wallet.flatMap { w in context.wallets.first { squeeze($0) == squeeze(w) } } ?? twin?.wallet
            item.reference = quoted(t.reference).flatMap(DocumentReader.reference(in:)) ?? twin?.reference
            item.note = t.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if kind == .expense || kind == .income {
                let allowed = Set((kind == .income ? DefaultKeys.incomeCategories : DefaultKeys.expenseCategories)
                    + context.categories.values + context.merchantRules.values)
                let name = (item.counterparty ?? "").lowercased()
                item.categoryKey = context.merchantRules.first { !name.isEmpty && name.contains($0.key) }?.value // the user's own edits win
                    ?? t.category.flatMap { c in [c, "category." + c].first(where: allowed.contains) } ?? twin?.categoryKey
            }
            items.append(item)
        }
        return items.isEmpty ? nil : DocRead(type: type, items: items)
    }

    /// Lowercase, no diacritics, no spaces: "32.000  đ" and "32.000đ" are the same words.
    private static func squeeze(_ s: String) -> String {
        Token.fold(s.lowercased().precomposedStringWithCanonicalMapping).filter { !$0.isWhitespace }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Assistant {
    /// Reads a photographed document with the first model whose reading checks out, else with the rules.
    /// `image`: a JPEG for models that see images; one that fails with it is asked again with the OCR rows only.
    func readDocument(_ lines: [OCRLine], image: Data?, context: ParserContext) async -> (read: DocRead, usedModel: Bool) {
        let rules = DocumentReader.read(lines, context: context)
        guard !lines.isEmpty, !skillsOff.contains(Skill.receiptReader.id) else { return (rules, false) }
        for model in router.candidates(for: .parse) {
            let instructions = documentInstructions(short: model.isSmall, context: context, language: model.replyLanguage ?? language)
            let text = DocumentReader.layoutText(lines, limit: model.isSmall ? 60 : 150)
            for picture in (model.acceptsImages && image != nil ? [image, nil] : [nil]) {
                guard let ai = try? await model.readDocument(instructions: instructions, text: text, image: picture) else { continue }
                if let read = DocumentExtractor.validate(ai, lines: lines, rules: rules, context: context) { return (read, true) }
                break
            }
        }
        return (rules, false)
    }

    private func documentInstructions(short: Bool, context: ParserContext, language: String) -> String {
        let categories = DefaultKeys.categories + context.categories.values
        return catalog.resolved(.receiptReader).instructions(language: language, short: short) + """


            Category keys: \(Array(Set(categories)).sorted().joined(separator: ", "))
            The user's wallets: \(context.wallets.joined(separator: ", "))
            Today: \(context.now.formatted(.iso8601.year().month().day()))
            """
    }
}

// MARK: - Apple Foundation Models

/// Apple's model leaves optional fields null (see `AppleParsedTxn`): required strings, empty = none.
@Generable(description: "A photographed money document and the transactions on it")
struct AppleDocRead {
    @Guide(description: "receipt, payment (bank or e-wallet confirmation), bill, statement (several transactions) or other (not money)",
           .anyOf(DocType.allCases.map(\.rawValue)))
    var docType: String
    var transactions: [AppleDocTxn]
}

@Generable(description: "One transaction on the document")
struct AppleDocTxn {
    @Guide(description: "The amount copied exactly from the text, e.g. \"32.000 đ\". Never compute.")
    var amountText: String
    @Guide(description: "expense, income, sent (to a person), received (from a person), lend, borrow or repay",
           .anyOf(DocRead.Kind.allCases.map(\.rawValue)))
    var kind: String
    @Guide(description: "The shop or the other person, copied from the text. Empty if none.")
    var counterparty: String
    @Guide(description: "The date and time copied from the text, e.g. \"19:38 - 05/11/2026\". Empty if none.")
    var dateText: String
    @Guide(description: "The app or bank it was paid with, e.g. MoMo. Empty if none.")
    var wallet: String
    @Guide(description: "The transaction or invoice id copied from the text. Empty if none.")
    var reference: String
    @Guide(description: "A category key from the list, only for expense or income. Empty if unsure.")
    var category: String

    var parsed: AIDocRead.Txn {
        func value(_ s: String) -> String? { s.trimmingCharacters(in: .whitespaces).nilIfEmpty }
        return .init(amountText: value(amountText), kind: kind, counterparty: value(counterparty), dateText: value(dateText),
                     wallet: value(wallet), reference: value(reference), category: value(category))
    }
}

extension AppleLLM {
    func readDocument(instructions: String, text: String, image: Data?) async throws -> AIDocRead {
        do {
            let read = try await LanguageModelSession(instructions: instructions).respond(to: text, generating: AppleDocRead.self).content
            return AIDocRead(docType: read.docType, transactions: read.transactions.map(\.parsed))
        } catch {
            throw AINotice(error)
        }
    }
}
