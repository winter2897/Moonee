import Foundation

/// SePay user API v2 (developer.sepay.vn/en/sepay-api/v2). The user creates a token at
/// my.sepay.vn → Cấu hình công ty → API Access. Rate limit: 3 requests/second/token.
struct SePayClient {
    var token: String
    var baseURL: URL = {
        #if DEBUG
        // `-sepayBaseURL http://127.0.0.1:8765/v2` points the simulator at a mock server.
        if let s = UserDefaults.standard.string(forKey: "sepayBaseURL"), let url = URL(string: s) { return url }
        #endif
        return URL(string: "https://userapi.sepay.vn/v2")!
    }()
    var session = URLSession.shared

    struct Account: Decodable, Hashable {
        let id: String
        let accountNumber: String
        let bankShortName: String?
        let label: String?
    }

    struct Transaction: Decodable {
        let id: String
        let transactionDate: String
        let accountNumber: String
        let amountIn: FlexInt
        let amountOut: FlexInt
        let transactionContent: String?
        let bankBrandName: String?
    }

    struct Page<T: Decodable>: Decodable {
        let data: [T]
        let meta: Meta?
        struct Meta: Decodable { let pagination: Pagination? }
        struct Pagination: Decodable { let hasMore: Bool? }
        var hasMore: Bool { meta?.pagination?.hasMore ?? false }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// SePay sends and expects Vietnam wall-clock time, "yyyy-MM-dd HH:mm:ss".
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func accounts() async throws -> [Account] {
        let page: Page<Account> = try await get("bank-accounts", ["per_page": "100"])
        return page.data
    }

    func transactions(since: Date) async throws -> [Transaction] {
        var all: [Transaction] = []
        for page in 1...50 { // ponytail: 5000 txns per sync cap, plenty for one person
            if page > 1 { try await Task.sleep(for: .milliseconds(350)) } // stay under 3 req/s
            let p: Page<Transaction> = try await get("transactions", [
                "transaction_date_from": Self.dateFormatter.string(from: since),
                "transaction_date_sort": "asc",
                "per_page": "100",
                "page": String(page),
            ])
            all += p.data
            if !p.hasMore || p.data.isEmpty { break }
        }
        return all
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        var req = URLRequest(url: baseURL.appending(path: path).appending(queryItems: query.map { URLQueryItem(name: $0.key, value: $0.value) }))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SePayError.http(code) }
        do { return try Self.decoder.decode(T.self, from: data) } catch { throw SePayError.badResponse }
    }
}

enum SePayError: LocalizedError {
    case http(Int), badResponse

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): "Token SePay không hợp lệ hoặc đã bị thu hồi."
        case .http(429): "SePay đang giới hạn tốc độ, thử lại sau ít phút."
        case .http(let code): "SePay trả lỗi \(code)."
        case .badResponse: "Không đọc được phản hồi từ SePay."
        }
    }
}

/// v2 documents integer amounts; v1 sent "18067000.00" strings. Accept both.
struct FlexInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i; return }
        if let d = try? c.decode(Double.self) { value = Int(d.rounded()); return }
        guard let d = Double(try c.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "amount is not a number")
        }
        value = Int(d.rounded())
    }
}

extension SePayClient.Transaction {
    var draft: BankDraft? {
        let net = amountIn.value - amountOut.value
        guard net != 0, let date = SePayClient.dateFormatter.date(from: transactionDate) else { return nil }
        return BankDraft(externalID: "sepay:\(id)", account: accountNumber, bank: bankBrandName ?? "Ngân hàng",
                         amount: abs(net), kind: net < 0 ? .expense : .income, date: date, memo: transactionContent ?? "")
    }
}
