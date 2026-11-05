import Foundation

/// Vietnamese parse dictionary: "30k", "1 củ", "2 lít", "1tr2", "hôm qua", "thứ 2 tuần trước", "cho Nam mượn 2tr".
extension Lexicon {
    static let vi = Lexicon(
        language: "vi",
        multipliers: [
            "k": 1_000, "nghìn": 1_000, "ngàn": 1_000, "ngh": 1_000,
            // ponytail: money talk only — "2 lít"/"5 xị" = 200k/500k, "5 trăm" = 500k.
            "trăm": 100_000, "lít": 100_000, "xị": 100_000,
            "tr": 1_000_000, "triệu": 1_000_000, "củ": 1_000_000,
            "tỷ": 1_000_000_000, "tỉ": 1_000_000_000, "tỏi": 1_000_000_000,
        ],
        currencies: ["đ": "VND", "₫": "VND", "vnđ": "VND", "vnd": "VND", "đồng": "VND", "đô": "USD", "usd": "USD"],
        dayOffsets: [
            "hôm nay": 0, "sáng nay": 0, "trưa nay": 0, "chiều nay": 0, "tối nay": 0,
            "hôm qua": -1, "tối qua": -1, "đêm qua": -1, "sáng qua": -1, "trưa qua": -1, "chiều qua": -1,
            "hôm kia": -2, "tuần trước": -7,
        ],
        weekdays: [
            "thứ 2": 2, "thứ hai": 2, "t2": 2, "thứ 3": 3, "thứ ba": 3, "t3": 3, "thứ 4": 4, "thứ tư": 4, "t4": 4,
            "thứ 5": 5, "thứ năm": 5, "t5": 5, "thứ 6": 6, "thứ sáu": 6, "t6": 6, "thứ 7": 7, "thứ bảy": 7, "t7": 7,
            "chủ nhật": 1, "cn": 1,
        ],
        lastWeekSuffixes: ["tuần trước", "tuần rồi"],
        dayOfMonthPrefixes: ["ngày", "mùng", "mồng"],
        kindPatterns: [
            (.transfer, "trả nợ thẻ"), (.transfer, "trả thẻ"), (.transfer, "thanh toán thẻ"),
            (.transfer, "rút tiền"), (.transfer, "nạp tiền vào"), (.transfer, "nạp * vào"),
            (.transfer, "chuyển * sang|qua|vào"), (.transfer, "chuyển * từ"),
            (.borrow, "* cho mình|tôi|tớ|tao|em|tui mượn|vay"), (.borrow, "mượn|vay của *"),
            (.lend, "cho * mượn|vay"), (.lend, "cho vay *"),
            (.borrow, "vay|mượn *"),
            (.repay, "trả nợ *"), (.repay, "* trả nợ"), (.repay, "trả lại *"), (.repay, "* trả lại"), (.repay, "thu nợ *"),
            (.income, "lương"), (.income, "thưởng"), (.income, "nhận"), (.income, "thu nhập"), (.income, "được cho"),
            (.income, "được tặng"), (.income, "hoàn tiền"), (.income, "tiền về"), (.income, "lãi"), (.income, "cổ tức"),
            (.income, "bán"), (.income, "hoa hồng"),
        ],
        notPerson: ["tiền", "nợ", "lại", "mình", "tôi", "tớ", "tao", "tui", "của", "lọ", "thẻ"],
        honorifics: ["anh", "chị", "em", "cô", "chú", "bác", "ông", "bà", "bạn", "cậu", "dì", "mợ", "thím"],
        toMarkers: ["sang", "qua", "vào"],
        separators: ["và", "rồi"],
        categories: [
            ("category.food", ["ăn", "uống", "cà phê", "cafe", "cf", "coffee", "trà sữa", "trà", "cơm", "phở", "bún", "bánh mì",
                               "bánh", "nhậu", "bia", "ăn trưa", "ăn sáng", "ăn tối", "highlands", "starbucks", "đi chợ", "lẩu", "nước", "kem"]),
            ("category.transport", ["grab", "taxi", "xăng", "gửi xe", "đổ xăng", "xanh sm", "vé xe", "xe buýt", "bus",
                                    "vé máy bay", "gojek", "rửa xe", "sửa xe"]),
            ("category.housing", ["tiền nhà", "thuê nhà", "tiền điện", "tiền nước", "internet", "wifi"]),
            ("category.shopping", ["shopee", "lazada", "tiki", "quần", "áo", "giày", "mua sắm", "siêu thị", "mỹ phẩm"]),
            ("category.entertainment", ["phim", "xem phim", "netflix", "spotify", "game", "karaoke", "du lịch"]),
            ("category.health", ["thuốc", "khám", "bệnh viện", "gym", "nha khoa"]),
            ("category.education", ["sách", "học phí", "khoá học", "khóa học", "học"]),
            ("category.charity", ["từ thiện", "quyên góp", "ủng hộ"]),
            ("category.salary", ["lương"]),
            ("category.bonus", ["thưởng"]),
        ],
        jars: [
            ("jar.essentials", ["thiết yếu"]), ("jar.investing", ["đầu tư", "tự do tài chính"]), ("jar.savings", ["tiết kiệm"]),
            ("jar.growth", ["phát triển bản thân", "giáo dục"]), ("jar.play", ["hưởng thụ", "vui chơi"]), ("jar.giving", ["từ thiện", "cho đi"]),
        ],
        jarWords: ["lọ"],
        questionCues: ["bao nhiêu", "mấy", "thế nào", "như thế nào", "tại sao", "làm sao", "có nên", "nên làm gì", "gợi ý", "tư vấn", "được không"],
        skillCues: [
            ("close-management", ["chốt sổ", "cuối tháng", "tổng kết tháng", "báo cáo tháng", "kết thúc tháng"]),
            ("jar-budgeting", ["chia thu nhập", "chia lương", "cân đối", "phân bổ"]),
            ("market-lookup", ["giá vàng", "vàng sjc", "vàng pnj", "sjc", "pnj", "tỷ giá", "giá đô", "giá usd", "lãi suất",
                               "giá cổ phiếu", "chứng khoán", "vn-index", "vnindex", "bitcoin", "btc", "ethereum", "eth",
                               "tiền ảo", "crypto", "tin tức", "giá xăng", "tìm trên mạng", "tra cứu"]),
        ],
        periods: [
            "hôm nay": "today", "tuần này": "thisWeek", "tuần trước": "lastWeek", "tuần rồi": "lastWeek",
            "tháng này": "thisMonth", "tháng trước": "lastMonth", "tháng rồi": "lastMonth",
            "năm nay": "thisYear", "năm ngoái": "lastYear", "năm trước": "lastYear",
        ],
        receiptTotals: ["cần thanh toán", "khách phải trả", "tổng thanh toán", "tổng cộng", "tổng tiền", "thành tiền", "thanh toán", "tổng"]
    )
}
