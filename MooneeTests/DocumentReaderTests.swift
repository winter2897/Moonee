import Foundation
import SwiftData
import Testing
@testable import Moonee

/// Photos and screenshots of money documents (spec §3.1): the rules, the model check, and what the chat does with them.
struct DocumentReaderTests {
    static let cal = QuickParserTests.cal
    /// Friday 6 Nov 2026, 21:00.
    static let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 21))!

    static var context: ParserContext {
        var c = QuickParserTests.context
        c.now = now
        c.wallets = ["Tiền mặt", "Vietcombank", "Ví MoMo"]
        return c
    }

    func read(_ lines: [OCRLine]) -> DocRead { DocumentReader.read(lines, context: Self.context) }
    func at(_ day: Int, _ month: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Rules, one fixture each

    @Test func momoTransferIsTheBigAmountNotTheSpendingWidget() throws {
        let doc = read(DocFixtures.momo)
        #expect(doc.type == .payment)
        let item = try #require(doc.items.first)
        #expect(doc.items.count == 1)
        #expect(item.amount == 32_000 && item.currency == "VND")
        #expect(item.kind == .sent)
        #expect(item.counterparty == "Nguyễn Phước Thịnh")
        #expect(item.date == at(5, 11, 19, 38))
        #expect(item.wallet == "Ví MoMo")
        #expect(item.reference == "155310026979")
    }

    @Test func bankTransferConfirmation() throws {
        let doc = read(DocFixtures.bankTransfer)
        let item = try #require(doc.items.first)
        #expect(doc.type == .payment)
        #expect(item.amount == 500_000 && item.kind == .sent)
        #expect(item.counterparty == "NGUYEN VAN AN")
        #expect(item.reference == "FT26310123456")
        #expect(item.date == at(6, 11, 8, 15))
        #expect(item.wallet == "Vietcombank") // not the 12.345.678 balance either
    }

    @Test func foodOrderIsAReceiptWithItsTotal() throws {
        let doc = read(DocFixtures.foodOrder)
        let item = try #require(doc.items.first)
        #expect(doc.type == .receipt) // "thành công", but items and a total: a receipt
        #expect(item.amount == 130_000 && item.kind == .expense)
        #expect(item.counterparty == "Cơm Tấm Cali")
        #expect(item.categoryKey == "category.food")
        #expect(item.date == at(5, 11, 12, 30))
        #expect(item.reference == "05GF-123456789")
    }

    @Test func supermarketReceiptSkipsCashGivenAndChange() throws {
        let doc = read(DocFixtures.supermarket)
        let item = try #require(doc.items.first)
        #expect(doc.type == .receipt)
        #expect(item.amount == 121_500)
        #expect(item.counterparty == "CO.OP MART LÝ THƯỜNG KIỆT")
        #expect(item.date == at(4, 11, 18, 45))
    }

    @Test func electricityBill() throws {
        let doc = read(DocFixtures.electricity)
        let item = try #require(doc.items.first)
        #expect(doc.type == .bill)
        #expect(item.amount == 661_446)
        #expect(item.counterparty == "TỔNG CÔNG TY ĐIỆN LỰC TP.HCM")
        #expect(item.categoryKey == "category.housing")
        #expect(item.date == nil) // a billing period and a due date are not the day it was paid
    }

    @Test func eInvoiceFromAPDF() throws {
        let doc = read(DocFixtures.eInvoice)
        let item = try #require(doc.items.first)
        #expect(doc.type == .receipt)
        #expect(item.amount == 1_100_000)
        #expect(item.counterparty == "CÔNG TY TNHH THẾ GIỚI DI ĐỘNG")
    }

    @Test func statementGivesOneTransactionPerRow() {
        let doc = read(DocFixtures.statement)
        #expect(doc.type == .statement)
        #expect(doc.items.map(\.amount) == [500_000, 59_000, 15_000_000, 45_000])
        #expect(doc.items.map(\.kind) == [.expense, .expense, .income, .expense])
        #expect(doc.items.map(\.note) == ["Chuyển tiền cho NGUYEN VAN AN", "Highlands Coffee", "Lương tháng 10", "Grab"])
        #expect(doc.items.map { $0.date.map { Self.cal.component(.day, from: $0) } } == [5, 5, 4, 4])
        #expect(doc.items[1].categoryKey == "category.food" && doc.items[3].categoryKey == "category.transport")
    }

    @Test func chatScreenshotIsNotMoney() {
        #expect(read(DocFixtures.chat) == DocRead(type: .other, items: []))
    }

    @Test func datesAreSane() {
        let c = Self.context
        #expect(DocumentReader.date(in: "05/11/2026", context: c) == at(5, 11, 12))
        #expect(DocumentReader.date(in: "31/02/2026", context: c) == nil) // no such day
        #expect(DocumentReader.date(in: "05/11/2019", context: c) == nil) // years ago
        #expect(DocumentReader.date(in: "20/11/2026", context: c) == nil) // the future
        #expect(DocumentReader.date(in: "Từ 05/10/2026 đến 04/11/2026", context: c) == nil) // a period
    }

    @Test func layoutTextTellsModelsWhereAndHowBig() {
        #expect(DocumentReader.layoutText([DocFixtures.row("32.000  đ", 0.195, 0.045)]) == "[y 20, h 45] 32.000  đ")
        #expect(DocumentReader.layoutText(OCRLine.plain(["Tổng cộng  58.000"])) == "Tổng cộng  58.000")
    }

    // MARK: A model's reading is checked against the page

    func assistant(_ model: any LLM) -> Assistant {
        Assistant(router: AIRouter(mode: .byok, onDevice: nil, local: nil, cloud: model), tools: Books.tools, language: "vi", skillsOff: [])
    }

    static func reply(_ type: String, _ txns: String) -> String { #"{"docType":"\#(type)","transactions":[\#(txns)]}"# }
    static let momoReply = reply("payment", #"""
        {"amountText":"32.000 đ","currency":"VND","kind":"sent","counterparty":"Nguyễn Phước Thịnh","dateText":"19:38 - 05/11/2026",
         "wallet":"Ví MoMo","reference":"#155310026979","category":null,"confidence":0.95,"note":null}
        """#)

    @Test func modelReadingThatMatchesThePageIsUsed() async throws {
        let model = ScriptedLLM(replies: [Self.momoReply])
        let (doc, used) = await assistant(model).readDocument(DocFixtures.momo, image: nil, context: Self.context)
        #expect(used)
        let item = try #require(doc.items.first)
        #expect(item.amount == 32_000 && item.kind == .sent && item.counterparty == "Nguyễn Phước Thịnh")
        #expect(item.reference == "155310026979" && item.wallet == "Ví MoMo" && item.date == at(5, 11, 19, 38))
        let req = try #require(model.requests.first)
        #expect(req.system.contains("receipt-reader") && req.system.contains("Ví MoMo"))
        #expect(req.messages.first?.text.contains("[y 20, h 45] 32.000  đ") == true) // the rows with their layout
        #expect(req.messages.first?.images.isEmpty == true) // a text-only model gets no image
    }

    @Test(arguments: [
        reply("payment", #"{"amountText":"33.000 đ","kind":"sent"}"#),                  // not on the page
        reply("payment", #"{"amountText":"1.695.304đ","kind":"expense"}"#),           // MoMo's spending widget, not the transfer
        reply("receipt", #"{"amountText":"32.000","kind":"teleport"}"#),                 // no such kind
        reply("other", ""),                                                               // the rules see a confirmation
        "Sorry, I can't read images.",
    ])
    func modelReadingThatDoesNotCheckOutFallsBackToTheRules(reply: String) async throws {
        let (doc, used) = await assistant(ScriptedLLM(replies: [reply])).readDocument(DocFixtures.momo, image: nil, context: Self.context)
        #expect(!used)
        #expect(doc == read(DocFixtures.momo))
    }

    @Test func modelMayCallAPhotoNotMoneyWhenTheRulesAgree() async {
        let (doc, used) = await assistant(ScriptedLLM(replies: [Self.reply("other", "")])).readDocument(DocFixtures.chat, image: nil, context: Self.context)
        #expect(used && doc.type == .other && doc.items.isEmpty)
    }

    @Test func modelDatesMustBeSane() async throws {
        let future = Self.momoReply.replacing("05/11/2026", with: "05/11/2027")
        let (doc, _) = await assistant(ScriptedLLM(replies: [future])).readDocument(DocFixtures.momo, image: nil, context: Self.context)
        #expect(doc.items.first?.date == at(5, 11, 19, 38)) // not quoted from the page → the page's own date
    }

    @Test func visionModelSeesTheImageAndRetriesWithoutIt() async throws {
        let model = VisionLLM(replies: [.failure(LLMError("HTTP 400: image input not supported", status: 400)), .success(Self.momoReply)])
        let (doc, used) = await assistant(model).readDocument(DocFixtures.momo, image: Data([0xFF, 0xD8]), context: Self.context)
        #expect(used && doc.items.first?.amount == 32_000)
        #expect(model.requests.map { $0.messages[0].images.count } == [1, 0])
    }

    @Test func cloudClientsSendTheImage() async throws {
        let msg = LLMMessage(role: .user, text: "rows", images: [Data([1, 2])])
        let openAI = try #require(OpenAICompatibleLLM.content(msg) as? [[String: Any]])
        #expect((openAI[1]["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64,AQI=")
        let anthropic = try #require(AnthropicLLM.content(msg) as? [[String: Any]])
        #expect((anthropic[0]["source"] as? [String: String])?["data"] == "AQI=")
        #expect(OpenAICompatibleLLM.content(LLMMessage(role: .user, text: "hi")) as? String == "hi")
        #expect(!OpenAICompatibleLLM(baseURL: "", apiKey: "", model: "", provider: .deepSeek).acceptsImages)

        let stub = StubTransport([["candidates": [["content": ["parts": [["text": "{}"]]]]]]])
        _ = try await GeminiLLM(apiKey: "k", model: "m", send: stub.send).respond(LLMRequest(system: "s", messages: [msg]))
        let parts = try #require(((stub.bodies[0]["contents"] as? [[String: Any]])?[0]["parts"]) as? [[String: Any]])
        #expect((parts[0]["inline_data"] as? [String: String])?["data"] == "AQI=")
    }
}

/// A cloud model that sees images; replies (or fails) in order.
final class VisionLLM: LLM, @unchecked Sendable {
    var replies: [Result<String, any Error>]
    var requests: [LLMRequest] = []
    var acceptsImages: Bool { true }

    init(replies: [Result<String, any Error>]) { self.replies = replies }

    func respond(_ r: LLMRequest) async throws -> String {
        requests.append(r)
        return try replies.removeFirst().get()
    }
}

/// What the chat does with a read document: ask what a transfer was, skip one already saved, let the user's words win.
@MainActor struct DocumentChatTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        Seed.ifNeeded(container.mainContext)
        context.insert(Wallet(name: "Ví MoMo", type: .ewallet, order: 1))
    }

    func parser() -> ParserContext {
        var c = ParserContext(context)
        (c.currency, c.now, c.calendar, c.dayFirst) = ("VND", DocumentReaderTests.now, DocumentReaderTests.cal, true)
        return c
    }

    func momo(_ said: String = "") throws -> ParsedTxn {
        try #require(ChatBook.receipt(DocFixtures.momo, context: parser(), described: said).first)
    }

    @Test func aTransferToAPersonAsksWhatItWas() throws {
        var p = try momo()
        let book = ChatBook.Lookup(context)
        #expect(book.unresolved(p) == .kind)
        #expect(book.choices(.kind, for: p).count == 3)
        #expect(ChatLines.question(.kind, p).contains("Nguyễn Phước Thịnh"))
        #expect(ChatBook.save([p], source: .image, rawInput: "", in: context).isEmpty) // nothing saved before the answer

        #expect(ChatBook.fill(&p, .kind, from: ChatBook.kindChoices(p)[1].title, context: parser())) // "I lent it"
        let t = try #require(ChatBook.save([p], source: .image, rawInput: "", in: context).first)
        #expect(t.kind == .lend && t.amount == 32_000)
        #expect(t.debt?.person == "Nguyễn Phước Thịnh")
        #expect(t.wallet?.name == "Ví MoMo")
        #expect(t.date == DocumentReaderTests.cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 19, minute: 38)))
        #expect(t.externalID == "doc:155310026979")
    }

    @Test func spendingIsAnAnswerToo() throws {
        var p = try momo()
        #expect(ChatBook.fill(&p, .kind, from: ChatBook.kindChoices(p)[0].title, context: parser()))
        let t = try #require(ChatBook.save([p], source: .image, rawInput: "", in: context).first)
        #expect(t.kind == .expense && t.category?.key == "category.other")
    }

    @Test func theSameScreenshotIsNotSavedTwice() throws {
        var p = try momo("tiền cơm") // the words say what it was: no question
        #expect(p.missing.isEmpty && p.kind == .expense && p.categoryKey == "category.food")
        #expect(ChatBook.save([p], source: .image, rawInput: "", in: context).count == 1)
        let again = ChatBook.fresh([p, p], in: context)
        #expect(again.fresh.isEmpty && again.duplicates == 2)
        p.reference = nil
        #expect(ChatBook.fresh([p], in: context).fresh.count == 1)
    }

    @Test func wordsCanSayItWasALoan() throws {
        let p = try momo("cho Thịnh mượn")
        #expect(p.kind == .lend && p.missing.isEmpty)
        #expect(p.amount == 32_000) // the screenshot's amount
    }

    @Test func aStatementSavesEveryRow() {
        let parsed = ChatBook.receipt(DocFixtures.statement, context: parser(), described: "sao kê tháng này")
        let saved = ChatBook.save(parsed, source: .image, rawInput: "", in: context)
        #expect(saved.map(\.amount) == [500_000, 59_000, 15_000_000, 45_000])
        #expect(saved.map(\.kind) == [.expense, .expense, .income, .expense])
        #expect(saved[1].note == "Highlands Coffee") // the user's words don't rename every row
    }

    @Test func aNonMoneyPhotoSavesNothing() {
        #expect(ChatBook.receipt(DocFixtures.chat, context: parser()).isEmpty)
    }
}
