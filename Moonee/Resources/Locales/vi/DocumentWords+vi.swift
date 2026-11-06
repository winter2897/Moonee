import Foundation

/// Vietnamese words on receipts, bank / e-wallet confirmations (MoMo, ZaloPay, VCB…), bills and statements.
extension DocumentWords {
    static let vi = DocumentWords(
        language: "vi",
        success: ["giao dịch thành công", "chuyển tiền thành công", "thanh toán thành công", "thành công", "đã chuyển", "hoàn tất"],
        transfer: ["chuyển tiền", "chuyển khoản", "chuyển thêm", "người nhận", "tài khoản nhận", "người thụ hưởng"],
        incoming: ["nhận tiền thành công", "bạn đã nhận", "đã nhận", "nhận được", "người gửi", "người chuyển"],
        amountLabels: ["số tiền chuyển", "số tiền thanh toán", "số tiền giao dịch", "số tiền"],
        toLabels: ["tên người nhận", "người nhận", "tài khoản nhận", "người thụ hưởng", "chuyển đến", "tới", "đến"],
        fromLabels: ["người gửi", "người chuyển", "tài khoản nguồn", "từ tài khoản", "từ"],
        merchantLabels: ["tên đơn vị bán hàng", "đơn vị bán hàng", "tên người bán", "người bán", "đơn vị cung cấp", "nhà cung cấp", "cửa hàng"],
        referenceLabels: ["mã giao dịch", "mã gd", "mã tham chiếu", "số tham chiếu", "số hóa đơn", "mã hóa đơn", "mã đơn hàng", "mã đơn", "số giao dịch"],
        titles: ["hóa đơn", "biên lai", "phiếu thanh toán", "phiếu tính tiền", "chi tiết đơn hàng", "chi tiết giao dịch"],
        bill: ["tiền điện", "điện lực", "evn", "kwh", "tiền nước", "cấp nước", "cước", "internet", "truyền hình", "kỳ hóa đơn", "chỉ số"],
        statement: ["sao kê", "lịch sử giao dịch", "biến động số dư"],
        chromeSections: ["quản lý chi tiêu", "ưu đãi", "có thể bạn quan tâm", "gợi ý cho bạn", "dành riêng cho bạn", "khám phá thêm"],
        chromeLines: ["số dư", "tổng chi", "tổng thu", "cùng kỳ", "tiền khách đưa", "tiền thừa", "tiền thối", "trả lại", "phí giao dịch",
                      "giảm giá", "khuyến mãi", "đã tiết kiệm", "hoàn tiền", "ưu đãi", "điểm thưởng"],
        walletWords: ["ví", "tài khoản", "tk", "thẻ", "ngân hàng"]
    )
}
