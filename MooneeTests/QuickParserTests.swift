import Foundation
import Testing
@testable import Moonee

struct QuickParserTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()
    let cats = ["Ăn uống", "Nhà ở", "Di chuyển", "Mua sắm", "Khác", "Lương", "Thưởng"]
    /// Sunday 1 Nov 2026, noon.
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))! }

    func parse(_ s: String) -> ParsedEntry? { QuickParser.parse(s, categories: cats, now: now, calendar: cal) }
    func day(_ d: Date) -> Int { cal.component(.day, from: d) }

    @Test(arguments: [
        ("cà phê 45k", 45_000),
        ("ăn trưa 1tr2 hôm qua", 1_200_000),
        ("lương 15 triệu", 15_000_000),
        ("grab 32.000đ", 32_000),
        ("1,5tr tiền nhà", 1_500_000),
        ("1.5 tr tiền nhà", 1_500_000),
        ("bánh mì 20 nghìn", 20_000),
        ("trà sữa 35 ngàn", 35_000),
        ("gửi xe 2k5", 2_500),
        ("điện thoại 1tr250", 1_250_000),
        ("tiền nhà 3.500.000", 3_500_000),
        ("shopee 1,200,000 đ", 1_200_000),
        ("cafe 45", 45_000),
        ("2 ly cà phê 90k", 90_000),
        ("laptop 1 tỷ", 1_000_000_000),
        ("học phí 2 củ", 2_000_000),
    ])
    func amounts(text: String, amount: Int) {
        #expect(parse(text)?.amount == amount)
    }

    @Test func noAmountIsNil() {
        #expect(parse("ăn trưa với bạn") == nil)
        #expect(parse("") == nil)
    }

    @Test func kind() {
        #expect(parse("cà phê 45k")?.kind == .expense)
        #expect(parse("lương 15 triệu")?.kind == .income)
        #expect(parse("nhận 500k từ mẹ")?.kind == .income)
        #expect(parse("+200k mẹ cho")?.kind == .income)
        #expect(parse("thưởng tết 5tr")?.kind == .income)
        #expect(parse("bánh mì 20k")?.kind == .expense) // "bánh" is not "bán"
    }

    @Test func dates() {
        #expect(day(parse("cà phê 45k")!.date) == 1)
        #expect(day(parse("cà phê 45k hôm nay")!.date) == 1)
        #expect(day(parse("ăn trưa 1tr2 hôm qua")!.date) == 31)
        #expect(day(parse("an trua 50k hom qua")!.date) == 31) // no diacritics
        #expect(day(parse("nhậu 300k tối qua")!.date) == 31)
        #expect(day(parse("xem phim 200k hôm kia")!.date) == 30)
        #expect(day(parse("thứ 2 đi chợ 200k")!.date) == 26)
        #expect(day(parse("đi chợ thứ bảy 150k")!.date) == 31)
        #expect(day(parse("t6 ăn lẩu 400k")!.date) == 30)
        #expect(day(parse("chủ nhật cafe 30k")!.date) == 1)
    }

    @Test func notes() {
        #expect(parse("cà phê 45k")?.note == "Cà phê")
        #expect(parse("ăn trưa 1tr2 hôm qua")?.note == "Ăn trưa")
        #expect(parse("thứ 2 đi chợ 200k")?.note == "Đi chợ")
        #expect(parse("thu nhập phụ 2tr")?.note == "Thu nhập phụ") // "thu" not eaten as "thứ"
        #expect(parse("2 ly cà phê 90k")?.note == "2 ly cà phê")
    }

    @Test func categories() {
        #expect(parse("cà phê 45k")?.category == "Ăn uống")
        #expect(parse("grab 32.000đ")?.category == "Di chuyển")
        #expect(parse("lương 15 triệu")?.category == "Lương")
        #expect(parse("tiền nhà 3tr")?.category == "Nhà ở")
        #expect(parse("mua sắm 500k")?.category == "Mua sắm") // direct name match
        #expect(parse("abc xyz 100k")?.category == nil)
        #expect(parse("thuốc cảm 50k")?.category == nil) // "Sức khoẻ" not in the list
    }

    @Test func receiptTotal() {
        #expect(QuickParser.receiptTotal([
            "HIGHLANDS COFFEE", "Ngày 01/11/2026 09:30", "Phin sữa đá 2 29.000 58.000",
            "Tổng cộng", "58.000", "Tiền khách đưa 100.000",
        ]) == 58_000)
        #expect(QuickParser.receiptTotal(["CỘNG", "TỔNG TIỀN: 125,000 VND", "Cảm ơn quý khách"]) == 125_000)
        #expect(QuickParser.receiptTotal(["Total 1,250,000"]) == 1_250_000)
        #expect(QuickParser.receiptTotal(["Bánh 15.000", "Nước 20.000", "Hotline 1900 1234"]) == 20_000) // fallback: largest grouped
        #expect(QuickParser.receiptTotal(["no numbers here"]) == nil)
    }
}
