import Foundation
import SwiftData
import Testing
import UIKit
@testable import Moonee

/// Photos and files attached in the composer, sent with the user's words (owner feedback round 4).
@MainActor struct ChatAttachmentTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(for: Schema.moonee, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        Seed.ifNeeded(container.mainContext)
    }

    func parser() -> ParserContext {
        var c = ParserContext(context)
        c.currency = "VND"
        return c
    }

    let highlands = OCRLine.plain(["HIGHLANDS COFFEE", "Phin sữa đá  29.000", "Bánh mì  29.000", "Tổng cộng  58.000"])
    let pho = OCRLine.plain(["PHỞ THÌN", "Phở bò  65.000", "Trà đá  5.000", "Tổng cộng  70.000"])

    @Test func noTextKeepsTheReceiptsOwnReading() {
        let c = parser() // one clock for both
        #expect(ChatBook.receipt(highlands, context: c, described: "  ") == ChatBook.receipt(highlands, context: c))
    }

    @Test func theUsersWordsNameAndCategoriseTheReceipt() throws {
        let t = try #require(ChatBook.receipt(pho, context: parser(), described: "ăn trưa với team hôm qua").first)
        #expect(t.amount == 70_000) // the receipt's total
        #expect(t.note.localizedCaseInsensitiveContains("ăn trưa với team"))
        #expect(t.categoryKey == "category.food")
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: .now))
        #expect(Calendar.current.isDate(t.date, inSameDayAs: yesterday))
        #expect(t.missing.isEmpty)
    }

    @Test func aJarTheUserNamesIsWhereTheExpenseGoes() throws {
        let t = try #require(ChatBook.receipt(highlands, context: parser(), described: "cafe với bạn, lọ hưởng thụ").first)
        #expect(t.jar == "jar.play")
        let saved = try #require(ChatBook.save([t], source: .image, rawInput: "", in: context).first)
        #expect(saved.jar?.key == "jar.play")
        #expect(saved.source == .image)
    }

    @Test func aPhotoWithNoMoneyGivesNothing() {
        // The chat then reads the words alone ("grab về nhà 45k"): `ChatView.send(_:with:)`.
        #expect(ChatBook.receipt(OCRLine.plain(["GRAB", "Chuyến đi"]), context: parser(), described: "grab về nhà 45k").isEmpty)
    }

    @Test func severalReceiptsMakeSeveralTransactions() {
        let parsed = [highlands, pho].flatMap { ChatBook.receipt($0, context: parser(), described: "đi chơi Đà Lạt") }
        let saved = ChatBook.save(parsed, source: .image, rawInput: "", in: context)
        #expect(saved.map(\.amount) == [58_000, 70_000])
        #expect(saved.allSatisfy { $0.jar != nil && $0.category != nil })
    }

    @Test func aSentMessageKeepsSmallThumbnailsAndFileNames() throws {
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1600)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
        }
        let stored = ChatAttachment(content: .image(photo)).stored
        let thumb = try #require(stored.thumbnail.flatMap(UIImage.init(data:)))
        #expect(max(thumb.size.width, thumb.size.height) * thumb.scale <= 240)

        let m = ChatMessage(fromUser: true, text: "ăn trưa")
        m.attachments = [stored, StoredAttachment(name: "hoadon.pdf")]
        #expect(m.attachments.map(\.name) == [nil, "hoadon.pdf"])
        m.attachments = []
        #expect(m.attachmentsData == nil)
    }
}
