import Foundation
import SwiftData
import SwiftUI

enum TxKind: String, Codable, CaseIterable {
    case expense, income
    var title: String { self == .expense ? "Chi tiêu" : "Thu nhập" }
}

/// Where a transaction came from. AI/bank features key off this.
enum TxSource: String, Codable {
    case manual, text, voice, photo, bank
}

enum WalletType: String, Codable, CaseIterable {
    case cash, bank, credit

    var title: String {
        switch self {
        case .cash: "Tiền mặt"
        case .bank: "Ngân hàng"
        case .credit: "Thẻ tín dụng"
        }
    }

    var symbol: String {
        switch self {
        case .cash: "banknote.fill"
        case .bank: "building.columns.fill"
        case .credit: "creditcard.fill"
        }
    }

    var color: Color {
        switch self {
        case .cash: .mooneeGreen
        case .bank: Color(hex: 0x3B82F6)
        case .credit: Color(hex: 0xF59E0B)
        }
    }
}

/// Named `Txn` to avoid clashing with SwiftUI.Transaction.
@Model final class Txn {
    /// VND, always positive; `kind` gives the sign.
    var amount: Int
    var kind: TxKind
    var date: Date
    var note: String
    var source: TxSource
    /// Original text / OCR / bank memo, kept so the AI accountant can (re)classify.
    var rawInput: String?
    var category: Category?
    var wallet: Wallet?
    /// Bank/statement transaction id (e.g. "sepay:<uuid>", "csv:<ref>") so re-imports are skipped.
    var externalID: String?
    var createdAt = Date()

    init(amount: Int, kind: TxKind, date: Date = .now, note: String = "", source: TxSource = .manual,
         rawInput: String? = nil, category: Category? = nil, wallet: Wallet? = nil) {
        self.amount = amount
        self.kind = kind
        self.date = date
        self.note = note
        self.source = source
        self.rawInput = rawInput
        self.category = category
        self.wallet = wallet
    }

    var signed: Int { kind == .expense ? -amount : amount }
}

@Model final class Category {
    var name: String
    /// SF Symbol name.
    var icon: String
    var colorHex: Int
    var kind: TxKind
    var jar: Jar?
    @Relationship(deleteRule: .nullify, inverse: \Txn.category) var txns: [Txn] = []

    init(name: String, icon: String, colorHex: Int, kind: TxKind = .expense, jar: Jar? = nil) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.kind = kind
        self.jar = jar
    }

    var color: Color { Color(hex: colorHex) }
}

@Model final class Wallet {
    var name: String
    var type: WalletType
    var initialBalance: Int
    var creditLimit: Int?
    var order: Int
    @Relationship(deleteRule: .cascade, inverse: \Txn.wallet) var txns: [Txn] = []

    init(name: String, type: WalletType, initialBalance: Int = 0, creditLimit: Int? = nil, order: Int = 0) {
        self.name = name
        self.type = type
        self.initialBalance = initialBalance
        self.creditLimit = creditLimit
        self.order = order
    }

    // ponytail: computed from txns, cache it if wallets get thousands of txns
    var balance: Int { initialBalance + txns.reduce(0) { $0 + $1.signed } }
}

/// A money jar (6-jar rule). Percents should sum to 100.
@Model final class Jar {
    var name: String
    var icon: String
    var colorHex: Int
    var percent: Int
    var order: Int
    @Relationship(deleteRule: .nullify, inverse: \Category.jar) var categories: [Category] = []

    init(name: String, icon: String, colorHex: Int, percent: Int, order: Int) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.percent = percent
        self.order = order
    }

    var color: Color { Color(hex: colorHex) }
}

enum Seed {
    /// First launch: default jars, categories and a cash wallet.
    @MainActor static func ifNeeded(_ context: ModelContext) {
        guard (try? context.fetchCount(FetchDescriptor<Jar>())) == 0 else { return }

        let jars = [
            Jar(name: "Thiết yếu", icon: "house.fill", colorHex: 0x22C55E, percent: 55, order: 0),
            Jar(name: "Đầu tư", icon: "chart.line.uptrend.xyaxis", colorHex: 0x3B82F6, percent: 10, order: 1),
            Jar(name: "Tiết kiệm", icon: "banknote.fill", colorHex: 0x14B8A6, percent: 10, order: 2),
            Jar(name: "Phát triển bản thân", icon: "book.fill", colorHex: 0x8B5CF6, percent: 10, order: 3),
            Jar(name: "Hưởng thụ", icon: "sparkles", colorHex: 0xF59E0B, percent: 10, order: 4),
            Jar(name: "Từ thiện", icon: "heart.fill", colorHex: 0xEF4444, percent: 5, order: 5),
        ]
        jars.forEach(context.insert)
        let (needs, edu, play, give) = (jars[0], jars[3], jars[4], jars[5])

        [
            Category(name: "Ăn uống", icon: "fork.knife", colorHex: 0xEAB308, jar: needs),
            Category(name: "Nhà ở", icon: "house.fill", colorHex: 0xF97316, jar: needs),
            Category(name: "Di chuyển", icon: "car.fill", colorHex: 0xEF4444, jar: needs),
            Category(name: "Sức khoẻ", icon: "cross.case.fill", colorHex: 0x14B8A6, jar: needs),
            Category(name: "Mua sắm", icon: "cart.fill", colorHex: 0x6366F1, jar: play),
            Category(name: "Giải trí", icon: "gamecontroller.fill", colorHex: 0xEC4899, jar: play),
            Category(name: "Học tập", icon: "book.fill", colorHex: 0x8B5CF6, jar: edu),
            Category(name: "Từ thiện", icon: "heart.fill", colorHex: 0xEF4444, jar: give),
            Category(name: "Khác", icon: "ellipsis", colorHex: 0x64748B),
            Category(name: "Lương", icon: "dollarsign.circle.fill", colorHex: 0x22C55E, kind: .income),
            Category(name: "Thưởng", icon: "gift.fill", colorHex: 0xF59E0B, kind: .income),
            Category(name: "Thu khác", icon: "plus.circle.fill", colorHex: 0x64748B, kind: .income),
        ].forEach(context.insert)

        context.insert(Wallet(name: "Ví tiền mặt", type: .cash))
    }
}
