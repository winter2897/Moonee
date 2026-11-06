import Foundation
@testable import Moonee

/// OCR output of real-looking money documents, with layout (`y` = top of the row, `h` = text height, both as a share
/// of the page), as `ReceiptScanner` returns it: rows top to bottom, pieces of one row joined by two spaces.
enum DocFixtures {
    static func row(_ text: String, _ y: Double, _ h: Double = 0.014) -> OCRLine { OCRLine(text: text, y: y, height: h) }

    /// The owner's MoMo screenshot (923 × 2000): a 32.000 đ transfer, then MoMo's "Quản lý chi tiêu" widget and an ad.
    static let momo = [
        row("19:38  5G  95", 0.025, 0.018),
        row("Giao dịch thành công  Chia sẻ", 0.145, 0.022),
        row("32.000  đ", 0.195, 0.045),
        row("Chưa phân loại", 0.265),
        row("19:38 - 05/11/2026 - Mã giao dịch: #155310026979", 0.303),
        row("Từ", 0.352, 0.013),
        row("Trần Hải Quân", 0.38, 0.016),
        row("Tới", 0.455, 0.013),
        row("Nguyễn Phước Thịnh", 0.482, 0.016),
        row("PT", 0.5, 0.011),
        row("MoMo - ********899", 0.512),
        row("Giao dịch hoàn thành chỉ trong: 1,0 giây", 0.563, 0.012),
        row("Chuyển thêm  Trò chuyện", 0.617, 0.016),
        row("Quản lý chi tiêu", 0.7, 0.018),
        row("Tháng 11", 0.73, 0.013),
        row("Tổng chi  Chi cho danh mục", 0.77, 0.011),
        row("1.695.304đ  Chưa phân loại", 0.79, 0.017),
        row("1.462.338đ  32.000đ", 0.855, 0.015),
        row("Cùng kỳ tháng 10  Xem chi tiết", 0.872, 0.011),
        row("Ưu đãi 50% riêng bạn", 0.935, 0.017),
        row("Mua Bảo hiểm Sức khỏe+, chi trả 5 tỷ/năm cho 37", 0.96),
        row("bệnh hiểm nghèo", 0.98),
    ]

    /// A Vietcombank transfer confirmation.
    static let bankTransfer = [
        row("Vietcombank", 0.05, 0.02),
        row("Chuyển tiền thành công", 0.2, 0.025),
        row("500.000 VND", 0.25, 0.04),
        row("Năm trăm nghìn đồng", 0.3),
        row("Tên người nhận  NGUYEN VAN AN", 0.4, 0.016),
        row("Tài khoản nhận  0123456789", 0.43, 0.016),
        row("Ngân hàng nhận  Techcombank", 0.46, 0.016),
        row("Mã giao dịch  FT26310123456", 0.5, 0.016),
        row("Thời gian  06/11/2026 08:15", 0.53, 0.016),
        row("Phí giao dịch  Miễn phí", 0.56, 0.016),
        row("Số dư khả dụng  12.345.678 VND", 0.59, 0.016),
    ]

    /// A ShopeeFood order screen: items, fees, a discount, then the total.
    static let foodOrder = [
        row("19:02  4G  80", 0.02, 0.018),
        row("Đơn hàng đã giao thành công", 0.08, 0.02),
        row("Cơm Tấm Cali - Nguyễn Trãi", 0.12, 0.02),
        row("Mã đơn hàng: 05GF-123456789", 0.15),
        row("2x  Cơm sườn bì chả  130.000đ", 0.25),
        row("1x  Trà đá  5.000đ", 0.28),
        row("Tạm tính  135.000đ", 0.33),
        row("Phí giao hàng  15.000đ", 0.36),
        row("Giảm giá  -20.000đ", 0.39),
        row("Tổng cộng  130.000đ", 0.42, 0.02),
        row("Thanh toán bằng MoMo", 0.45),
        row("05/11/2026 12:30", 0.5),
    ]

    /// A paper supermarket receipt.
    static let supermarket = [
        row("CO.OP MART LÝ THƯỜNG KIỆT", 0.05, 0.02),
        row("ĐC: 497 Hòa Hảo, Q.10", 0.08),
        row("HÓA ĐƠN BÁN HÀNG", 0.12, 0.018),
        row("Ngày: 04/11/2026 18:45", 0.15),
        row("Sữa tươi Vinamilk 1L  2  64.000", 0.22),
        row("Trứng gà 10 quả  1  32.500", 0.25),
        row("Bánh mì sandwich  1  25.000", 0.28),
        row("Tổng cộng:  121.500", 0.34, 0.018),
        row("Tiền khách đưa:  200.000", 0.37),
        row("Tiền thối lại:  78.500", 0.4),
        row("Cảm ơn quý khách", 0.45),
    ]

    /// An EVN electricity bill.
    static let electricity = [
        row("TỔNG CÔNG TY ĐIỆN LỰC TP.HCM", 0.05, 0.018),
        row("HÓA ĐƠN TIỀN ĐIỆN", 0.09, 0.022),
        row("Kỳ hóa đơn: 10/2026", 0.13),
        row("Từ ngày 05/10/2026 đến ngày 04/11/2026", 0.16),
        row("Chỉ số mới  12.345  Chỉ số cũ  12.100", 0.22),
        row("Điện năng tiêu thụ  245 kWh", 0.25),
        row("Tiền điện  612.450", 0.3),
        row("Thuế GTGT (8%)  48.996", 0.33),
        row("Tổng cộng tiền thanh toán  661.446", 0.38, 0.02),
        row("Hạn thanh toán: 15/11/2026", 0.42),
    ]

    /// A PDF e-invoice: its text, no layout.
    static let eInvoice = OCRLine.plain([
        "HÓA ĐƠN GIÁ TRỊ GIA TĂNG",
        "(VAT INVOICE)",
        "Ngày 03 tháng 11 năm 2026",
        "Ký hiệu: 1C26TAA  Số: 0001234",
        "Tên đơn vị bán hàng: CÔNG TY TNHH THẾ GIỚI DI ĐỘNG",
        "Mã số thuế: 0303217354",
        "Tên người mua: Trần Hải Quân",
        "STT  Tên hàng hóa, dịch vụ  Đơn vị tính  Số lượng  Đơn giá  Thành tiền",
        "1  Tai nghe Bluetooth  Cái  1  1.000.000  1.000.000",
        "Cộng tiền hàng: 1.000.000",
        "Thuế suất GTGT: 10%  Tiền thuế GTGT: 100.000",
        "Tổng cộng tiền thanh toán: 1.100.000",
        "Số tiền viết bằng chữ: Một triệu một trăm nghìn đồng",
    ])

    /// A bank app's history: date headers, one signed row per transaction.
    static let statement = [
        row("Lịch sử giao dịch", 0.08, 0.022),
        row("05/11/2026", 0.15),
        row("Chuyển tiền cho NGUYEN VAN AN  -500.000 VND", 0.19),
        row("Highlands Coffee  -59.000 VND", 0.24),
        row("04/11/2026", 0.3),
        row("Lương tháng 10  +15.000.000 VND", 0.34),
        row("Grab  -45.000 VND", 0.39),
    ]

    /// A chat screenshot: no money.
    static let chat = [
        row("09:41", 0.02, 0.018),
        row("Minh", 0.07, 0.02),
        row("Tối nay đi ăn không?", 0.2, 0.016),
        row("Ok 7h nhé, quán số 25", 0.25, 0.016),
        row("Đã xem", 0.3, 0.012),
    ]
}
