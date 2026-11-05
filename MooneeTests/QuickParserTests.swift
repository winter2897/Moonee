import Foundation
import Testing
@testable import Moonee

struct QuickParserTests {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        c.firstWeekday = 2 // Monday, as in Vietnam
        return c
    }()
    /// Sunday 1 Nov 2026, noon.
    static let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!

    static var context: ParserContext {
        var c = ParserContext()
        c.currency = "VND"
        c.now = now
        c.calendar = cal
        c.dayFirst = true
        c.wallets = ["Tiền mặt", "Vietcombank", "MoMo"]
        return c
    }
    var ctx: ParserContext { Self.context }

    func parse(_ s: String, currency: String = "VND") -> [ParsedTxn] {
        var c = ctx
        c.currency = currency
        return QuickParser.parse(s, context: c)
    }
    func one(_ s: String, currency: String = "VND") -> ParsedTxn? {
        let all = parse(s, currency: currency)
        return all.count == 1 ? all[0] : nil
    }
    func day(_ d: Date?) -> String {
        guard let d else { return "nil" }
        let c = Self.cal.dateComponents([.month, .day], from: d)
        return "\(c.day!)/\(c.month!)"
    }

    // MARK: Amounts

    @Test(arguments: [
        ("cà phê 45k", 45_000), ("ăn trưa 1tr2 hôm qua", 1_200_000), ("lương 15 triệu", 15_000_000),
        ("grab 32.000đ", 32_000), ("1,5tr tiền nhà", 1_500_000), ("1.5 tr tiền nhà", 1_500_000),
        ("bánh mì 20 nghìn", 20_000), ("trà sữa 35 ngàn", 35_000), ("gửi xe 2k5", 2_500), ("điện thoại 1tr250", 1_250_000),
        ("tiền nhà 3.500.000", 3_500_000), ("shopee 1,200,000 đ", 1_200_000), ("cafe 45", 45_000), ("2 ly cà phê 90k", 90_000),
        ("laptop 1 tỷ", 1_000_000_000), ("học phí 2 củ", 2_000_000), ("nhậu 2 lít", 200_000), ("đổ xăng 1 xị", 100_000),
        ("tiền nhà 5 trăm", 500_000), ("mua điện thoại 1 triệu 2", 1_200_000), ("an trua 50k", 50_000), ("phở 45K", 45_000),
    ])
    func vndAmounts(text: String, amount: Int) {
        #expect(one(text)?.amount == amount)
        #expect(one(text)?.currency == "VND")
    }

    @Test func currencyAwareSlang() {
        // Spec §10.2: "45k" is 45,000 ₫ in VND and $45,000 in USD (minor units: cents).
        #expect(one("phở 45k", currency: "VND")?.amount == 45_000)
        #expect(one("laptop 45k", currency: "USD")?.amount == 4_500_000)
        #expect(one("coffee 4.50", currency: "USD")?.amount == 450)
        #expect(one("coffee 45", currency: "USD")?.amount == 4_500) // "bare 45 = 45k" is Vietnamese-đồng only
        #expect(one("car 3 grand", currency: "USD")?.amount == 300_000)
        // A currency in the text wins over the default.
        let usd = one("lunch $12 yesterday", currency: "VND")
        #expect(usd?.amount == 1_200)
        #expect(usd?.currency == "USD")
        #expect(one("ăn trưa 45đ", currency: "USD")?.amount == 45)
        #expect(one("ăn trưa 45đ", currency: "USD")?.currency == "VND")
        #expect(one("quà 20 đô")?.currency == "USD")
        #expect(one("dinner 30 euros", currency: "USD")?.currency == "EUR")
    }

    @Test func minorUnits() {
        #expect(Money.fractionDigits("VND") == 0)
        #expect(Money.fractionDigits("USD") == 2)
        #expect(Money.fractionDigits("JPY") == 0)
        #expect(Money.format(1_250_000, currency: "VND", locale: Locale(identifier: "vi_VN")).replacing(#/\s/#, with: " ") == "1.250.000 ₫")
        #expect(Money.format(1_250, currency: "USD", locale: Locale(identifier: "en_US")) == "$12.50")
    }

    @Test func noAmount() {
        #expect(parse("").isEmpty)
        #expect(parse("hôm qua").isEmpty)
        #expect(parse("xin chào Moonee").isEmpty)
        // Spec §3.2: a transaction without an amount comes back so Moonee asks, never guesses.
        let lunch = one("ăn trưa với bạn")
        #expect(lunch?.amount == nil)
        #expect(lunch?.missing == [.amount])
        #expect(lunch?.categoryKey == "category.food")
    }

    // MARK: Several per sentence

    @Test func multipleTransactions() {
        let three = parse("phở 45k, cafe 29k, grab 32k")
        #expect(three.map(\.amount) == [45_000, 29_000, 32_000])
        #expect(three.map(\.note) == ["Phở", "Cafe", "Grab"])
        #expect(three.map(\.categoryKey) == ["category.food", "category.food", "category.transport"])

        #expect(parse("phở 45k cafe 29k grab 32k").map(\.amount) == [45_000, 29_000, 32_000])
        #expect(parse("phở 45k và cafe 29k").map(\.amount) == [45_000, 29_000])
        #expect(parse("lunch 12$ and coffee 4$", currency: "USD").map(\.amount) == [1_200, 400])
        #expect(parse("tiền nhà 1,500,000; điện 300k").map(\.amount) == [1_500_000, 300_000])
        // Amountless words join the next piece instead of becoming a transaction.
        #expect(parse("ăn trưa và cafe 100k").map(\.amount) == [100_000])
        // A date said once covers the whole message; a piece's own date wins.
        #expect(parse("hôm qua phở 45k, cafe 29k hôm nay").map { day($0.date) } == ["31/10", "1/11"])
        #expect(parse("phở 45k, cafe 29k hôm qua").map { day($0.date) } == ["31/10", "31/10"])
    }

    // MARK: Kinds

    @Test func incomeAndExpense() {
        #expect(one("cà phê 45k")?.kind == .expense)
        #expect(one("lương 15 triệu")?.kind == .income)
        #expect(one("lương 15 triệu")?.categoryKey == "category.salary")
        #expect(one("nhận 500k từ mẹ")?.kind == .income)
        #expect(one("+200k mẹ cho")?.kind == .income)
        #expect(one("+200k mẹ cho")?.note == "Mẹ cho")
        #expect(one("thưởng tết 5tr")?.categoryKey == "category.bonus")
        #expect(one("bánh mì 20k")?.kind == .expense) // "bánh" is not "bán"
        #expect(one("salary 3000", currency: "USD")?.kind == .income)
    }

    @Test func lendBorrowRepay() {
        let lend = one("cho Nam mượn 2tr")
        #expect(lend?.kind == .lend)
        #expect(lend?.person == "Nam")
        #expect(lend?.amount == 2_000_000)
        #expect(lend?.missing == [])

        let borrow = one("vay mẹ 5 củ hôm kia")
        #expect(borrow?.kind == .borrow)
        #expect(borrow?.person == "mẹ")
        #expect(day(borrow?.date) == "30/10")

        #expect(one("Nam cho mình mượn 2tr")?.kind == .borrow)
        #expect(one("Nam cho mình mượn 2tr")?.person == "Nam")
        #expect(one("cho anh Tuấn vay 3 củ")?.person == "anh Tuấn")
        #expect(one("mượn của chị Lan 500k")?.person == "chị Lan")
        #expect(one("cho vay 1tr")?.missing == [.person])

        #expect(one("trả nợ Nam 1tr")?.kind == .repay)
        #expect(one("trả nợ Nam 1tr")?.person == "Nam")
        #expect(one("Hùng trả nợ 500k")?.person == "Hùng")
        #expect(one("trả tiền điện 500k")?.kind == .expense) // paying a bill is not repaying a debt

        #expect(one("lent Tom $50")?.kind == .lend)
        #expect(one("lent Tom $50")?.person == "Tom")
        #expect(one("lent 50 to Anna", currency: "USD")?.person == "Anna")
        #expect(one("borrowed 200 from Mike", currency: "USD")?.kind == .borrow)
        #expect(one("borrowed 200 from Mike", currency: "USD")?.person == "Mike")
        #expect(one("Sara lent me 20 bucks")?.kind == .borrow)
        #expect(one("Sara lent me 20 bucks")?.person == "Sara")
        #expect(one("Tom paid me back 50", currency: "USD")?.kind == .repay)
        #expect(one("Tom paid me back 50", currency: "USD")?.person == "Tom")
    }

    @Test func transfers() {
        let t = one("chuyển 2tr từ Vietcombank sang MoMo")
        #expect(t?.kind == .transfer)
        #expect(t?.wallet == "Vietcombank")
        #expect(t?.toWallet == "MoMo")
        #expect(t?.missing == [])

        let reversed = one("chuyển sang MoMo 500k từ Vietcombank")
        #expect(reversed?.wallet == "Vietcombank")
        #expect(reversed?.toWallet == "MoMo")

        #expect(one("rút tiền 2tr")?.kind == .transfer)
        #expect(one("rút tiền 2tr")?.missing == [.toWallet])
        #expect(one("trả thẻ tín dụng 5tr")?.kind == .transfer) // card payment is a transfer, not spending (spec §4.2)
        #expect(one("Vietcombank MoMo 1tr")?.kind == .transfer) // two wallets, no other cue
        #expect(one("moved 200 from MoMo to Vietcombank", currency: "USD")?.toWallet == "Vietcombank")
        // Spending from a named wallet keeps the hint.
        #expect(one("cafe 45k bằng momo")?.wallet == "MoMo")
        #expect(one("cafe 45k bằng momo")?.kind == .expense)
    }

    @Test func jarTransfers() {
        let j = one("chuyển 500k từ lọ hưởng thụ sang lọ tiết kiệm")
        #expect(j?.kind == .jarTransfer)
        #expect(j?.jar == "jar.play")
        #expect(j?.toJar == "jar.savings")

        var c = ctx
        c.jars = ["Du lịch Nhật": "jar.custom.trip"]
        let custom = QuickParser.parse("chuyển 1tr sang Du lịch Nhật", context: c)
        #expect(custom.first?.kind == .jarTransfer)
        #expect(custom.first?.toJar == "jar.custom.trip")
        #expect(custom.first?.missing == [.jar])

        #expect(one("move 100 from savings to fun jar", currency: "USD")?.toJar == "jar.play")
    }

    // MARK: Dates

    @Test(arguments: [
        ("cà phê 45k", "1/11"), ("cà phê 45k hôm nay", "1/11"), ("ăn trưa 1tr2 hôm qua", "31/10"),
        ("an trua 50k hom qua", "31/10"), ("nhậu 300k tối qua", "31/10"), ("bánh mì 20k sáng nay", "1/11"),
        ("xem phim 200k hôm kia", "30/10"), ("thứ 2 đi chợ 200k", "26/10"), ("đi chợ thứ bảy 150k", "31/10"),
        ("t6 ăn lẩu 400k", "30/10"), ("chủ nhật cafe 30k", "1/11"), ("grab 32k thứ 2 tuần trước", "19/10"),
        ("chủ nhật tuần trước cafe 30k", "25/10"), ("ngày 5 tiền điện 500k", "5/10"), ("ngày 1 tiền nhà 3tr", "1/11"),
        ("5/10 tiền nhà 3tr", "5/10"), ("25/12 quà 500k", "25/12"),
        ("lunch $12 yesterday", "31/10"), ("taxi $20 last monday", "26/10"), ("dinner $40 last sunday", "25/10"),
        ("coffee $5 sunday", "1/11"), ("movie $15 friday last week", "23/10"),
    ])
    func dates(text: String, expected: String) {
        #expect(day(one(text)?.date) == expected)
    }

    @Test func lastWeekFromAMonday() {
        var c = ctx
        c.now = Self.cal.date(byAdding: .day, value: 1, to: Self.now)! // Monday 2 Nov
        #expect(day(QuickParser.parse("cafe 30k chủ nhật tuần trước", context: c).first?.date) == "1/11")
        #expect(day(QuickParser.parse("cafe 30k thứ 2 tuần trước", context: c).first?.date) == "26/10")
    }

    @Test func dayFirstFollowsRegion() {
        var c = ctx
        c.dayFirst = false
        #expect(day(QuickParser.parse("taxi $20 10/5", context: c).first?.date) == "5/10")
    }

    // MARK: Notes, categories, learning

    @Test func notes() {
        #expect(one("cà phê 45k")?.note == "Cà phê")
        #expect(one("ăn trưa 1tr2 hôm qua")?.note == "Ăn trưa")
        #expect(one("thứ 2 đi chợ 200k")?.note == "Đi chợ")
        #expect(one("thu nhập phụ 2tr")?.note == "Thu nhập phụ") // "thu" is not eaten as "thứ"
        #expect(one("2 ly cà phê 90k")?.note == "2 ly cà phê")
    }

    @Test func categories() {
        #expect(one("cà phê 45k")?.categoryKey == "category.food")
        #expect(one("tiền nước 200k")?.categoryKey == "category.housing") // longest keyword beats "nước"
        #expect(one("abc xyz 100k")?.categoryKey == nil)
        #expect(one("thuốc cảm 50k")?.categoryKey == "category.health")
        #expect(one("uber 15", currency: "USD")?.categoryKey == "category.transport")
        #expect(one("cho Nam mượn 2tr")?.categoryKey == nil) // only spending and income get a category

        var c = ctx
        c.merchantRules = ["highlands": "category.custom.coffee"]
        c.categories = ["Thú cưng": "category.custom.pets"]
        #expect(QuickParser.parse("Highlands 59k", context: c).first?.categoryKey == "category.custom.coffee")
        #expect(QuickParser.parse("thú cưng 300k", context: c).first?.categoryKey == "category.custom.pets")
    }

    @Test func inputLanguageIndependentOfUI() {
        // Every lexicon is always on: English text parses whatever the UI language, and mixed input works.
        #expect(one("coffee 45k")?.categoryKey == "category.food")
        #expect(one("phở 45k yesterday")?.date == Self.cal.date(byAdding: .day, value: -1, to: Self.now))
        var c = ctx
        c.lexicons = [.vi]
        #expect(QuickParser.parse("lunch 12 dollars", context: c).first?.currency == "VND") // without en, "dollars" is unknown
    }

    @Test func helpers() {
        #expect(QuickParser.amount(in: "1tr2", context: ctx)?.amount == 1_200_000)
        #expect(QuickParser.amount(in: "đi chơi", context: ctx) == nil)
        #expect(day(QuickParser.date(in: "hôm qua", context: ctx)) == "31/10")
        #expect(QuickParser.isQuestion("tháng này ăn uống hết bao nhiêu"))
        #expect(QuickParser.isQuestion("How much did I spend?"))
        #expect(!QuickParser.isQuestion("phở 45k"))
    }

    @Test func receiptTotal() {
        #expect(QuickParser.receiptTotal([
            "HIGHLANDS COFFEE", "Ngày 01/11/2026 09:30", "Phin sữa đá 2 29.000 58.000",
            "Tổng cộng", "58.000", "Tiền khách đưa 100.000",
        ]) == 58_000)
        #expect(QuickParser.receiptTotal(["CỘNG", "TỔNG TIỀN: 125,000 VND", "Cảm ơn quý khách"]) == 125_000)
        #expect(QuickParser.receiptTotal(["Total 1,250,000"]) == 1_250_000)
        #expect(QuickParser.receiptTotal(["Bánh 15.000", "Nước 20.000", "Hotline 1900 1234"]) == 20_000)
        #expect(QuickParser.receiptTotal(["no numbers here"]) == nil)
    }

    @Test func lexiconsCoverEveryDefaultKey() {
        for l in Lexicon.all {
            #expect(Set(DefaultKeys.jars).isSubset(of: Set(l.jars.map(\.key))), "\(l.language) jars")
            #expect(Set(l.categories.map(\.key)).isSubset(of: Set(DefaultKeys.categories)), "\(l.language) unknown category key")
        }
    }
}
