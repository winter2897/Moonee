import Foundation
import Testing
@testable import Moonee

/// Thai and Lao input: no spaces between words, spelled-out numbers, บาท / ກີບ.
struct ThaiLaoParserTests {
    /// Sunday 1 Nov 2026, noon (as `QuickParserTests`).
    static let now = QuickParserTests.now
    let cal = QuickParserTests.cal

    func ctx(_ currency: String, wallets: [String]) -> ParserContext {
        var c = QuickParserTests.context
        c.currency = currency
        c.wallets = wallets
        return c
    }
    func th(_ s: String) -> [ParsedTxn] { QuickParser.parse(s, context: ctx("THB", wallets: ["เงินสด", "กสิกร", "TrueMoney"])) }
    func lo(_ s: String) -> [ParsedTxn] { QuickParser.parse(s, context: ctx("LAK", wallets: ["ເງິນສົດ", "BCEL", "LDB"])) }
    func baht(_ v: Decimal) -> Int { Money(major: v, "THB").minor }
    func kip(_ v: Decimal) -> Int { Money(major: v, "LAK").minor }
    func day(_ d: Date?) -> String {
        guard let d else { return "nil" }
        let c = cal.dateComponents([.month, .day], from: d)
        return "\(c.day!)/\(c.month!)"
    }

    // MARK: Tokens

    @Test func thaiAndLaoSplitIntoWords() {
        #expect(Token.split("ซื้อกาแฟ50บาท").map(\.original) == ["ซื้อ", "กาแฟ", "50", "บาท"])
        #expect(Token.split("ซื้อกาแฟ50บาท").map(\.glued) == [false, true, true, true])
        #expect(Token.split("ห้าสิบบาท").map(\.lower) == ["50", "บาท"])
        #expect(Token.split("กาแฟ๖๕บาท").map(\.lower) == ["กาแฟ", "65", "บาท"]) // Thai digits
        #expect(Token.split("2พัน").map(\.lower) == ["2", "พัน"])                 // a unit after digits stays a multiplier
        #expect(Token.split("ห้างสามี").count == 2)                              // "ห้า"/"สาม" inside words stay words
        #expect(Token.split("ຊາວຫ້າພັນກີບ").map(\.lower) == ["25000", "ກີບ"])
        #expect(Token.split("phở 45k").map(\.original) == ["phở", "45k"])        // other languages untouched
    }

    @Test(arguments: [
        ([5, 10], 50), ([2, 1_000, 5, 100], 2_500), ([1, 100, 2, 10, 1], 121), ([10, 1], 11), ([1_000, 5], 1_500),
        ([100_000, 5], 150_000), ([2, 1_000_000], 2_000_000), ([1, 1_000_000, 2, 100_000], 1_200_000),
        ([5, 10, 1_000], 50_000), ([10, 1, 1_000], 11_000), ([20, 5, 1_000], 25_000), ([1_000_000], 1_000_000),
    ])
    func spelledNumbers(parts: [Int], value: Int) {
        #expect(Token.value(of: parts) == value)
    }

    // MARK: Thai

    @Test func thaiAmounts() {
        #expect(th("กาแฟ 65บาท").first?.amount == baht(65))
        #expect(th("กาแฟ 65บาท").first?.currency == "THB")
        #expect(th("ข้าวมันไก่ห้าสิบบาท").first?.amount == baht(50))
        #expect(th("ค่าห้องสองพันห้าร้อยบาท").first?.amount == baht(2_500))
        #expect(th("ค่าเช่า 2พัน").first?.amount == baht(2_000))
        #expect(th("ค่าเทอม 1.5หมื่น").first?.amount == baht(15_000))
        #expect(th("ซื้อทีวี 2แสน5").first?.amount == baht(250_000))
        #expect(th("฿120 ชานม").first?.amount == baht(120))
        #expect(th("กาแฟ๖๕บาท").first?.amount == baht(65))
        #expect(th("ผัดไทย 60").first?.amount == baht(60))
        #expect(th("กาแฟ 3 ดอลลาร์").first?.currency == "USD")
    }

    @Test func thaiCategoriesAndNotes() {
        #expect(th("กาแฟ 65บาท").first?.categoryKey == "category.food")
        #expect(th("ค่าไฟ 800บาท").first?.categoryKey == "category.housing")
        #expect(th("แท็กซี่ไปสนามบิน 350").first?.categoryKey == "category.transport")
        #expect(th("ช้อปปี้ 499บาท").first?.categoryKey == "category.shopping")
        #expect(th("ข้าวมันไก่ร้านป้า 50บาท").first?.note == "ข้าวมันไก่ร้านป้า") // no spaces added
    }

    @Test func thaiSeveralPerMessage() {
        let two = th("กาแฟ 65บาท ข้าวผัด 60บาท")
        #expect(two.map(\.amount) == [baht(65), baht(60)])
        #expect(th("ข้าวมันไก่ 50 และ ชานม 45").map(\.amount) == [baht(50), baht(45)])
        let bills = th("ค่าไฟ 800บาท, ค่าน้ำ 150บาท เมื่อวาน")
        #expect(bills.map(\.categoryKey) == ["category.housing", "category.housing"])
        #expect(bills.map { day($0.date) } == ["31/10", "31/10"])
    }

    @Test func thaiKinds() {
        let lend = th("ให้พี่ต้นยืม 500")
        #expect(lend.first?.kind == .lend)
        #expect(lend.first?.person == "พี่ต้น")
        #expect(th("ยืมเงินแม่ 1000บาท").first.map { ($0.kind, $0.person) } ?? (.expense, nil) == (.borrow, "แม่"))
        #expect(th("สมชายให้ฉันยืม 300").first.map { ($0.kind, $0.person) } ?? (.expense, nil) == (.borrow, "สมชาย"))
        #expect(th("คืนเงินพี่ต้น 500").first.map { ($0.kind, $0.person) } ?? (.expense, nil) == (.repay, "พี่ต้น"))
        #expect(th("สมชายคืนเงิน 300").first.map { ($0.kind, $0.person) } ?? (.expense, nil) == (.repay, "สมชาย"))
        let salary = th("เงินเดือนเข้า 25000บาท")
        #expect(salary.first?.kind == .income)
        #expect(salary.first?.categoryKey == "category.salary")
        #expect(th("โบนัส 1หมื่น").first?.categoryKey == "category.bonus")
        #expect(th("ได้เงินคืน 50บาท").first?.kind == .income)
        #expect(th("ได้เงินคืนจากพี่ต้น 500").first.map { ($0.kind, $0.person) } ?? (.expense, nil) == (.repay, "พี่ต้น"))
        let move = th("โอน 1000 จากกสิกรไปเงินสด")
        #expect(move.first?.kind == .transfer)
        #expect(move.first.map { [$0.wallet, $0.toWallet] } == ["กสิกร", "เงินสด"])
        #expect(th("ถอนเงิน 2000 จากกสิกร").first?.kind == .transfer)
        let jars = th("โอน 500 จากกระปุกความสุขไปเงินออม")
        #expect(jars.first?.kind == .jarTransfer)
        #expect(jars.first.map { [$0.jar, $0.toJar] } == ["jar.play", "jar.savings"])
        #expect(th("กาแฟ 65บาท").first?.kind == .expense)
    }

    @Test func thaiDates() {
        #expect(day(th("กาแฟ 50 เมื่อวาน").first?.date) == "31/10")
        #expect(day(th("เมื่อวานซืนกินข้าว 80").first?.date) == "30/10")
        #expect(day(th("วันจันทร์ ข้าว 60").first?.date) == "26/10")
        #expect(day(th("วันจันทร์ที่แล้ว ข้าว 60").first?.date) == "19/10")
        #expect(day(th("วันที่ 5 ค่าไฟ 800").first?.date) == "5/10")
        #expect(day(th("กาแฟ 50 วันนี้").first?.date) == "1/11")
    }

    @Test func thaiQuestions() {
        #expect(QuickParser.isQuestion("เดือนนี้ใช้ไปเท่าไหร่"))
        #expect(!QuickParser.isQuestion("กาแฟ 65บาท"))
        #expect(QuickParser.hints(in: "เดือนนี้กินไปเท่าไหร่", context: ctx("THB", wallets: [])).period == "thisMonth")
    }

    // MARK: Lao

    @Test func laoAmounts() {
        #expect(lo("ເຝີ 35ພັນ").first?.amount == kip(35_000))
        #expect(lo("ເຝີ 35ພັນ").first?.currency == "LAK")
        #expect(lo("ກາເຟຊາວຫ້າພັນກີບ").first?.amount == kip(25_000))
        #expect(lo("ເຂົ້າປຽກ ຫ້າສິບພັນ").first?.amount == kip(50_000))
        #expect(lo("ຄ່າເຊົ່າ 1ລ້ານ2").first?.amount == kip(1_200_000))
        #expect(lo("ເບຍລາວ 2ໝື່ນ").first?.amount == kip(20_000))
        #expect(lo("ກາເຟ ₭25000").first?.amount == kip(25_000))
        #expect(lo("ຊື້ເສື້ອ 300 ບາດ").first?.currency == "THB")
    }

    @Test func laoCategories() {
        #expect(lo("ເຝີ 35ພັນ").first?.categoryKey == "category.food")
        #expect(lo("ຄ່າໄຟ 300ພັນ").first?.categoryKey == "category.housing")
        #expect(lo("ຕຸກຕຸກ 40ພັນ").first?.categoryKey == "category.transport")
        #expect(lo("ໃສ່ບາດ 50ພັນ").first?.categoryKey == "category.charity")
    }

    @Test func laoSeveralPerMessage() {
        let two = lo("ເຝີ 35ພັນ, ກາເຟ 25ພັນ ມື້ວານ")
        #expect(two.map(\.amount) == [kip(35_000), kip(25_000)])
        #expect(two.map { day($0.date) } == ["31/10", "31/10"])
        #expect(lo("ເຝີ 35ພັນ ແລະ ກາເຟ 25ພັນ").count == 2)
        #expect(lo("ເຝີ 35ພັນ ກາເຟ 25ພັນ ນ້ຳ 5ພັນ").count == 3)
    }

    @Test func laoKinds() {
        let lend = lo("ໃຫ້ອ້າຍສົມຊາຍຢືມ 200ພັນ")
        #expect(lend.first?.kind == .lend)
        #expect(lend.first?.person == "ອ້າຍສົມຊາຍ")
        #expect(lo("ຢືມເງິນແມ່ 500ພັນ").first.map { ($0.kind, $0.person) } ?? (.expense, nil) == (.borrow, "ແມ່"))
        #expect(lo("ສົ່ງເງິນຄືນອ້າຍສົມຊາຍ 200ພັນ").first.map { ($0.kind, $0.person) } ?? (.expense, nil) == (.repay, "ອ້າຍສົມຊາຍ"))
        #expect(lo("ໄດ້ເງິນຄືນ 50ພັນ").first?.kind == .income)
        let salary = lo("ເງິນເດືອນ 5ລ້ານ")
        #expect(salary.first?.kind == .income)
        #expect(salary.first?.categoryKey == "category.salary")
        let move = lo("ໂອນ 1ລ້ານ ຈາກ BCEL ໄປ ເງິນສົດ")
        #expect(move.first?.kind == .transfer)
        #expect(move.first.map { [$0.wallet, $0.toWallet] } == ["BCEL", "ເງິນສົດ"])
        #expect(lo("ຖອນເງິນ 500ພັນ ຈາກ BCEL").first?.kind == .transfer)
        let jars = lo("ໂອນ 100ພັນ ຈາກກະປຸກຄວາມສຸກ ໄປ ເງິນອອມ")
        #expect(jars.first?.kind == .jarTransfer)
        #expect(jars.first.map { [$0.jar, $0.toJar] } == ["jar.play", "jar.savings"])
    }

    @Test func laoDates() {
        #expect(day(lo("ກາເຟ 25ພັນ ມື້ວານ").first?.date) == "31/10")
        #expect(day(lo("ມື້ວານຊືນ ເຝີ 35ພັນ").first?.date) == "30/10")
        #expect(day(lo("ວັນຈັນ ເຝີ 35ພັນ").first?.date) == "26/10")
        #expect(day(lo("ວັນຈັນທີ່ແລ້ວ ເຝີ 35ພັນ").first?.date) == "19/10")
        #expect(QuickParser.isQuestion("ເດືອນນີ້ໃຊ້ໄປເທົ່າໃດ"))
    }
}
