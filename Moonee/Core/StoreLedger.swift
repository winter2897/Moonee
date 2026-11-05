import Foundation
import SwiftData

/// The stored books as plain values for the AI tools (`LedgerReading`) and any screen that wants them.
/// A snapshot taken on the main actor: build a fresh one per question.
// ponytail: reads every txn of the currency; fetch by date range once ledgers get big.
struct StoreLedger: LedgerReading {
    let currency: String
    let jarList: [LedgerJar]
    let txns: [LedgerTxn]

    @MainActor init(_ context: ModelContext, currency: String = Money.defaultCurrency) {
        let txns = (try? context.fetch(FetchDescriptor<Txn>())) ?? []
        let jars = (try? context.fetch(FetchDescriptor<Jar>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let wallets = (try? context.fetch(FetchDescriptor<Wallet>())) ?? []
        let ledger = Ledger(txns: txns, wallets: wallets, jars: jars)
        self.currency = currency
        jarList = jars.map { LedgerJar(key: $0.parserKey, name: $0.name, percent: $0.percent, balance: ledger.jarBalance($0.persistentModelID)) }
        self.txns = txns.filter { $0.currencyCode == currency }.map { t in
            LedgerTxn(date: t.date, amount: t.amount, kind: EntryKind(rawValue: t.kindRaw) ?? .expense,
                      categoryKey: t.category?.parserKey, categoryName: t.category?.name,
                      jarKey: t.jar?.parserKey, toJarKey: t.toJar?.parserKey,
                      splits: Dictionary((t.splits ?? []).compactMap { s in s.jar.map { ($0.parserKey, s.amount) } }, uniquingKeysWith: +),
                      note: t.note, person: t.debt?.person)
        }
    }

    func jars() async throws -> [LedgerJar] { jarList }
    func transactions(in i: DateInterval) async throws -> [LedgerTxn] { txns.filter { $0.date >= i.start && $0.date < i.end } }
}

extension ParserContext {
    /// What the parser should know from the store: wallets, jar and category names, learned merchant rules.
    @MainActor init(_ context: ModelContext, now: Date = .now) {
        self.init()
        currency = Money.defaultCurrency
        self.now = now
        wallets = ((try? context.fetch(FetchDescriptor<Wallet>(sortBy: [SortDescriptor(\.order)]))) ?? []).map(\.name)
        let byName = { (pairs: [(String, String)]) in Dictionary(pairs, uniquingKeysWith: { a, _ in a }) }
        jars = byName(((try? context.fetch(FetchDescriptor<Jar>())) ?? []).map { ($0.name, $0.parserKey) })
        categories = byName(((try? context.fetch(FetchDescriptor<Category>())) ?? []).map { ($0.name, $0.parserKey) })
        merchantRules = byName(((try? context.fetch(FetchDescriptor<MerchantRule>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? [])
            .compactMap { r in r.category.map { (r.pattern, $0.parserKey) } })
    }
}

// The parser and tools speak keys; user-made jars/categories have none, so they get one from their name.
// ponytail: renaming a custom category orphans its merchant-rule key text; use a stored UUID if renames matter.
extension Category {
    var parserKey: String { key ?? "category.custom.\(customName ?? "")" }
}

extension Jar {
    var parserKey: String { key ?? "jar.custom.\(customName ?? "")" }
}
