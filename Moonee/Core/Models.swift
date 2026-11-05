import Foundation
import SwiftData
import SwiftUI

// Data model v2, spec §11. CloudKit-ready: every stored property has a default or is optional,
// every relationship is optional with an explicit inverse, no unique constraints.
// Enums are stored as raw strings (`kindRaw`) so #Predicate can filter on them; use the typed accessor.
// Amounts are positive `Int` minor units + `currencyCode` (see Money.swift); `kind` gives the direction.

enum TxKind: String, Codable, CaseIterable {
    /// lend/borrow/repay move wallet money and the debt book, never jars. jarTransfer moves jar money, never wallets.
    case expense, income, transfer, jarTransfer, lend, borrow, repay

    var title: String {
        switch self {
        case .expense: String(localized: "Expense")
        case .income: String(localized: "Income")
        case .transfer: String(localized: "Transfer")
        case .jarTransfer: String(localized: "Jar transfer")
        case .lend: String(localized: "Lend")
        case .borrow: String(localized: "Borrow")
        case .repay: String(localized: "Repay")
        }
    }
}

/// Where a transaction came from. AI features key off this.
enum TxSource: String, Codable, CaseIterable {
    case manual, text, voice, image, `import`
}

enum WalletType: String, Codable, CaseIterable {
    case cash, bank, ewallet, credit

    var title: String {
        switch self {
        case .cash: String(localized: "Cash")
        case .bank: String(localized: "Bank account")
        case .ewallet: String(localized: "E-wallet")
        case .credit: String(localized: "Credit card")
        }
    }

    var symbol: String {
        switch self {
        case .cash: "banknote.fill"
        case .bank: "building.columns.fill"
        case .ewallet: "iphone.gen3"
        case .credit: "creditcard.fill"
        }
    }

    var color: Color {
        switch self {
        case .cash: .mooneeGreen
        case .bank: Color(hex: 0x3B82F6)
        case .ewallet: Color(hex: 0xEC4899)
        case .credit: Color(hex: 0xF59E0B)
        }
    }
}

enum DebtDirection: String, Codable, CaseIterable {
    /// lent: they owe me. borrowed: I owe them.
    case lent, borrowed
}

enum AssetKind: String, Codable, CaseIterable {
    case gold, silver, stock, fx, crypto, other
}

enum Frequency: String, Codable, CaseIterable {
    case daily, weekly, monthly, yearly

    var component: Calendar.Component {
        switch self {
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        case .yearly: .year
        }
    }
}

/// Default jars/categories store a `key` (`jar.essentials`) shown through the String Catalog;
/// a user-chosen name goes in `customName` and wins.
private func displayName(key: String?, customName: String?) -> String {
    if let customName, !customName.isEmpty { return customName }
    return key.map { String(localized: String.LocalizationValue($0)) } ?? ""
}

/// Named `Txn` to avoid clashing with SwiftUI.Transaction.
@Model final class Txn {
    var amount: Int = 0
    var currencyCode: String = Money.defaultCurrency
    var kindRaw: String = TxKind.expense.rawValue
    var date: Date = Date.now
    var note: String = ""
    var sourceRaw: String = TxSource.manual.rawValue
    /// Original text / OCR, kept so the AI can (re)classify.
    var rawInput: String?
    /// Statement line id (e.g. "csv:<ref>") so re-imports are skipped.
    var externalID: String?
    @Attribute(.externalStorage) var attachment: Data?
    var createdAt: Date = Date.now

    var category: Category?
    /// Source wallet; for income/borrow it is where the money lands.
    var wallet: Wallet?
    /// transfer only (a credit-card payment is a transfer into the card).
    var toWallet: Wallet?
    /// Expense jar, pinned at save by `allocate` (nil = no jar). jarTransfer: the source jar.
    var jar: Jar?
    /// jarTransfer only.
    var toJar: Jar?
    /// lend/borrow/repay.
    var debt: Debt?
    /// income only: how it was split into jars, written at save by `allocate`. Empty = unallocated.
    @Relationship(deleteRule: .cascade, inverse: \IncomeSplit.txn) var splits: [IncomeSplit]? = []

    init(amount: Int, kind: TxKind, currencyCode: String = Money.defaultCurrency, date: Date = .now, note: String = "",
         source: TxSource = .manual, rawInput: String? = nil, category: Category? = nil, wallet: Wallet? = nil) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.kindRaw = kind.rawValue
        self.date = date
        self.note = note
        self.sourceRaw = source.rawValue
        self.rawInput = rawInput
        self.category = category
        self.wallet = wallet
    }

    var kind: TxKind {
        get { TxKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var source: TxSource {
        get { TxSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    var money: Money { Money(amount, currencyCode) }

    /// Call once whenever a txn is created (chat, form, import, onboarding): pins an expense to its category's jar
    /// and splits an income by the jars' current percents, so later percent edits or category remaps keep history.
    /// Skips what is already set, so a manual split or jar choice wins.
    func allocate(jars: [Jar], in context: ModelContext) {
        switch kind {
        case .expense:
            if jar == nil { jar = category?.jar }
        case .income where (splits ?? []).isEmpty:
            for (jar, share) in Ledger<Jar>.split(amount, by: jars.sorted { $0.order < $1.order }.map { ($0, $0.percent) }) {
                let s = IncomeSplit(amount: share, jar: jar)
                context.insert(s)
                s.txn = self
            }
        default: break
        }
    }
}

/// One jar's share of one income (spec §4.1: split per income, editable per income).
@Model final class IncomeSplit {
    var amount: Int = 0
    var txn: Txn?
    var jar: Jar?

    init(amount: Int, jar: Jar?) {
        self.amount = amount
        self.jar = jar
    }
}

@Model final class Category {
    var key: String?
    var customName: String?
    /// SF Symbol name.
    var icon: String = "tag.fill"
    var colorHex: Int = 0x64748B
    /// .expense or .income only.
    var kindRaw: String = TxKind.expense.rawValue
    var order: Int = 0
    var jar: Jar?
    @Relationship(deleteRule: .nullify, inverse: \Txn.category) var txns: [Txn]? = []
    @Relationship(deleteRule: .nullify, inverse: \Recurring.category) var recurrings: [Recurring]? = []
    @Relationship(deleteRule: .cascade, inverse: \MerchantRule.category) var rules: [MerchantRule]? = []

    init(key: String? = nil, customName: String? = nil, icon: String, colorHex: Int, kind: TxKind = .expense, jar: Jar? = nil, order: Int = 0) {
        self.key = key
        self.customName = customName
        self.icon = icon
        self.colorHex = colorHex
        self.kindRaw = kind.rawValue
        self.jar = jar
        self.order = order
    }

    var name: String { displayName(key: key, customName: customName) }
    var kind: TxKind {
        get { TxKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }
    var color: Color { Color(hex: colorHex) }
}

@Model final class Wallet {
    var name: String = ""
    var typeRaw: String = WalletType.cash.rawValue
    var currencyCode: String = Money.defaultCurrency
    /// Opening balance, minor units. A credit card starts at 0 and goes negative as you swipe.
    var initialBalance: Int = 0
    var creditLimit: Int?
    /// Day of month (1–31), credit cards only.
    var statementDay: Int?
    var dueDay: Int?
    var order: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \Txn.wallet) var txns: [Txn]? = []
    @Relationship(deleteRule: .nullify, inverse: \Txn.toWallet) var incoming: [Txn]? = []
    @Relationship(deleteRule: .nullify, inverse: \Recurring.wallet) var recurrings: [Recurring]? = []

    init(name: String, type: WalletType, currencyCode: String = Money.defaultCurrency, initialBalance: Int = 0,
         creditLimit: Int? = nil, order: Int = 0) {
        self.name = name
        self.typeRaw = type.rawValue
        self.currencyCode = currencyCode
        self.initialBalance = initialBalance
        self.creditLimit = creditLimit
        self.order = order
    }

    var type: WalletType {
        get { WalletType(rawValue: typeRaw) ?? .cash }
        set { typeRaw = newValue.rawValue }
    }
}

/// An envelope (spec §4.1). Its balance is computed by `Ledger` and carries over month to month.
@Model final class Jar {
    var key: String?
    var customName: String?
    var icon: String = "star.fill"
    var colorHex: Int = 0x64748B
    /// Share of each income, 0–100; all jars sum to 100.
    var percent: Int = 0
    var order: Int = 0
    /// Opening balance in the default currency's minor units (onboarding).
    var initialBalance: Int = 0
    @Relationship(deleteRule: .nullify, inverse: \Category.jar) var categories: [Category]? = []
    @Relationship(deleteRule: .nullify, inverse: \Txn.jar) var txns: [Txn]? = []
    @Relationship(deleteRule: .nullify, inverse: \Txn.toJar) var incoming: [Txn]? = []
    @Relationship(deleteRule: .cascade, inverse: \IncomeSplit.jar) var splits: [IncomeSplit]? = []
    @Relationship(deleteRule: .nullify, inverse: \Goal.jar) var goals: [Goal]? = []

    init(key: String? = nil, customName: String? = nil, icon: String, colorHex: Int, percent: Int, order: Int) {
        self.key = key
        self.customName = customName
        self.icon = icon
        self.colorHex = colorHex
        self.percent = percent
        self.order = order
    }

    var name: String { displayName(key: key, customName: customName) }
    var color: Color { Color(hex: colorHex) }
}

/// Bills and subscriptions (spec §4.3). "Paid" creates a Txn and moves `nextDue` by one `frequency`.
@Model final class Recurring {
    var name: String = ""
    var amount: Int = 0
    var currencyCode: String = Money.defaultCurrency
    var isEstimate: Bool = false
    var frequencyRaw: String = Frequency.monthly.rawValue
    var nextDue: Date = Date.now
    var remindDaysBefore: Int = 1
    var wallet: Wallet?
    var category: Category?

    init(name: String, amount: Int, currencyCode: String = Money.defaultCurrency, frequency: Frequency = .monthly, nextDue: Date) {
        self.name = name
        self.amount = amount
        self.currencyCode = currencyCode
        self.frequencyRaw = frequency.rawValue
        self.nextDue = nextDue
    }

    var frequency: Frequency {
        get { Frequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }
}

@Model final class Goal {
    var name: String = ""
    var target: Int = 0
    var saved: Int = 0
    var currencyCode: String = Money.defaultCurrency
    var deadline: Date?
    /// Source jar (e.g. a laptop comes out of Play).
    var jar: Jar?

    init(name: String, target: Int, currencyCode: String = Money.defaultCurrency, deadline: Date? = nil, jar: Jar? = nil) {
        self.name = name
        self.target = target
        self.currencyCode = currencyCode
        self.deadline = deadline
        self.jar = jar
    }
}

/// One person in the debt book (spec §4.5). Amount and remaining come from its lend/borrow/repay txns via `Ledger`.
@Model final class Debt {
    var person: String = ""
    var directionRaw: String = DebtDirection.lent.rawValue
    var currencyCode: String = Money.defaultCurrency
    var dueDate: Date?
    var note: String = ""
    var createdAt: Date = Date.now
    @Relationship(deleteRule: .nullify, inverse: \Txn.debt) var txns: [Txn]? = []

    init(person: String, direction: DebtDirection, currencyCode: String = Money.defaultCurrency, dueDate: Date? = nil) {
        self.person = person
        self.directionRaw = direction.rawValue
        self.currencyCode = currencyCode
        self.dueDate = dueDate
    }

    var direction: DebtDirection {
        get { DebtDirection(rawValue: directionRaw) ?? .lent }
        set { directionRaw = newValue.rawValue }
    }
}

/// A holding valued at a price the user types (MVP: no live prices). "2 lượng SJC" = quantity 2, unitPrice per lượng.
@Model final class Asset {
    var symbol: String = ""
    var kindRaw: String = AssetKind.other.rawValue
    var quantity: Double = 0
    /// Price of one unit, minor units of `currencyCode`.
    var unitPrice: Int = 0
    var currencyCode: String = Money.defaultCurrency
    var costBasis: Int?
    var updatedAt: Date = Date.now

    init(symbol: String, kind: AssetKind, quantity: Double, unitPrice: Int, currencyCode: String = Money.defaultCurrency) {
        self.symbol = symbol
        self.kindRaw = kind.rawValue
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.currencyCode = currencyCode
    }

    var kind: AssetKind {
        get { AssetKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    var value: Int { Int((quantity * Double(unitPrice)).rounded()) }
}

/// Learned from the user's corrections: a merchant/note pattern → category (spec §3.2).
@Model final class MerchantRule {
    var pattern: String = ""
    var category: Category?
    var updatedAt: Date = Date.now

    init(pattern: String, category: Category?) {
        self.pattern = pattern
        self.category = category
    }
}

extension Schema {
    /// Every model. Register new `@Model` types here; the app and tests build their container from it.
    static let mooneeModels: [any PersistentModel.Type] = [Txn.self, IncomeSplit.self, Category.self, Wallet.self, Jar.self,
                                                           Recurring.self, Goal.self, Debt.self, Asset.self, MerchantRule.self]
    static let moonee = Schema(mooneeModels)
}

enum Seed {
    /// The 6-jar rule, also used by "Restore defaults".
    // ponytail: colours are S2's colour-blind-safe JarPalette.hex[0...5], inlined because S1 merges first; use JarPalette.hex[i] after S2 lands.
    static var defaultJars: [Jar] {
        [
            Jar(key: "jar.essentials", icon: "house.fill", colorHex: 0xEAB308, percent: 55, order: 0),
            Jar(key: "jar.investing", icon: "chart.line.uptrend.xyaxis", colorHex: 0x0D9488, percent: 10, order: 1),
            Jar(key: "jar.savings", icon: "banknote.fill", colorHex: 0x60A5FA, percent: 10, order: 2),
            Jar(key: "jar.growth", icon: "book.fill", colorHex: 0x9333EA, percent: 10, order: 3),
            Jar(key: "jar.play", icon: "sparkles", colorHex: 0xF472B6, percent: 10, order: 4),
            Jar(key: "jar.giving", icon: "heart.fill", colorHex: 0xA3E635, percent: 5, order: 5),
        ]
    }

    /// First launch: default jars, categories and a cash wallet.
    // ponytail: count check; with iCloud sync two fresh devices both seed — dedupe by key when S11 turns CloudKit on.
    @MainActor static func ifNeeded(_ context: ModelContext) {
        guard (try? context.fetchCount(FetchDescriptor<Jar>())) == 0 else { return }

        let jars = defaultJars
        jars.forEach(context.insert)
        let (needs, growth, play, giving) = (jars[0], jars[3], jars[4], jars[5])

        [
            Category(key: "category.food", icon: "fork.knife", colorHex: 0xEAB308, jar: needs),
            Category(key: "category.housing", icon: "house.fill", colorHex: 0xF97316, jar: needs),
            Category(key: "category.transport", icon: "car.fill", colorHex: 0xEF4444, jar: needs),
            Category(key: "category.health", icon: "cross.case.fill", colorHex: 0x14B8A6, jar: needs),
            Category(key: "category.shopping", icon: "cart.fill", colorHex: 0x6366F1, jar: play),
            Category(key: "category.entertainment", icon: "gamecontroller.fill", colorHex: 0xEC4899, jar: play),
            Category(key: "category.education", icon: "book.fill", colorHex: 0x8B5CF6, jar: growth),
            Category(key: "category.charity", icon: "heart.fill", colorHex: 0xEF4444, jar: giving),
            Category(key: "category.other", icon: "ellipsis", colorHex: 0x64748B),
            Category(key: "category.salary", icon: "dollarsign.circle.fill", colorHex: 0x22C55E, kind: .income),
            Category(key: "category.bonus", icon: "gift.fill", colorHex: 0xF59E0B, kind: .income),
            Category(key: "category.otherIncome", icon: "plus.circle.fill", colorHex: 0x64748B, kind: .income),
        ].enumerated().forEach { i, c in
            c.order = i
            context.insert(c)
        }

        // A wallet name is user data, so it is stored already translated.
        context.insert(Wallet(name: String(localized: "Cash wallet"), type: .cash))
    }
}

extension Ledger where ID == PersistentIdentifier {
    /// The ledger for the stored data. Jars move only through what `Txn.allocate` pinned.
    init(txns: [Txn], wallets: [Wallet], jars: [Jar]) {
        let entries = txns.map { t in
            Entry(kind: t.kind, amount: t.amount, date: t.date,
                  wallet: t.wallet?.persistentModelID, toWallet: t.toWallet?.persistentModelID,
                  jar: t.jar?.persistentModelID,
                  toJar: t.toJar?.persistentModelID, debt: t.debt?.persistentModelID,
                  splits: Dictionary((t.splits ?? []).compactMap { s in s.jar.map { ($0.persistentModelID, s.amount) } },
                                     uniquingKeysWith: +))
        }
        self.init(entries: entries,
                  walletOpening: Dictionary(uniqueKeysWithValues: wallets.map { ($0.persistentModelID, $0.initialBalance) }),
                  jarOpening: Dictionary(uniqueKeysWithValues: jars.map { ($0.persistentModelID, $0.initialBalance) }),
                  debtDirections: Dictionary(txns.compactMap { $0.debt.map { ($0.persistentModelID, $0.direction) } }, uniquingKeysWith: { a, _ in a }))
    }
}
